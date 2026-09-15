// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// Data.xc — Object-style wrapper around a (pointer, length) byte block.
// =================================================================
//
// First step toward heterogeneous collections: a Data instance owns
// a heap-allocated byte buffer of a given length. Unlike String, it
// does NOT add a trailing null and the bytes are treated as opaque
// (no character-class operations).
//
// Usage:
//   u8 raw[4] = { $DE, $AD, $BE, $EF };
//   Data* d = Data.withBytes(&raw[0], (u16)4);
//   for (u16 i = (u16)0; i < d.length(); i++)
//       Stdio.printf("%02x ", d.byteAt(i));
//
// Notes:
//   * Heap-capable targets only — the 6502 `xt` layouts and every native
//     backend. A bump-only target rejects `new u8[N]`.
//
//   * `withBytes(src, len)` copies `len` bytes from `src` into a
//     fresh heap allocation. The caller's source pointer can be
//     freed / reused immediately afterwards.
//
//   * `withCapacity(len)` RESERVES room for `len` bytes and comes back
//     empty, so appends fill from the front without reallocating. Use
//     `withLength(len)` for `len` zero-filled bytes to write through
//     `setByteAt`.
//
//   * `bytes()` returns the raw u8* for direct access. The pointer
//     remains valid as long as the Data instance does.

// Data implicitly inherits from the runtime's built-in `Object`
// root class — see the matching note on Number.xc — so a Data*
// fits anywhere an Object* is expected. Conforms to Comparable so
// heterogeneous collection helpers can compare blobs through the
// protocol's vtable.
//
// ── xt6502 build of this class ───────────────────────────────────────────
// The 6502 Foundation. Counts, indices and lengths are u16 and the hash is
// u8, because on an 8-bit CPU a 32-bit index is four bytes of arithmetic on
// every compare and every increment, and a container that could address more
// than 65535 elements could not fit them anyway — one heap block is capped
// at a 12 KB bank. The 32-bit machines (arm64, arm9, m68k, x86_64) use
// `support/generic/lib/` instead, which is uncapped and hashes 32-bit.
//
// Same API, different implementation. Neither target pays for the other's
// constraints.
//
// Only the files whose WIDTHS differ live here. Everything width-neutral —
// Object, Comparable, Sort, the Foundation umbrella — exists once, in
// generic/lib, and is shared: a library file's `#import "X.xc"` resolves
// through the platform's lib dir first and generic/lib second, never against
// its own directory. So generic/lib/Object.xc picks up THIS String and THIS
// Hashable when the target is the 6502.
//

#import "String.xc"
#import "Comparable.xc"
#import "Hashable.xc"

// Free a Data's byte buffer. `new u8[N]` comes from the same allocator as any
// object — a heap header with refcount 1 and no destructor — so releasing it to
// zero reclaims it. Null-safe.
//
// The 6502 build uses a raw `_heap_free` instead: a raw buffer there carries no
// destructor descriptor, and the ARC release path dispatches one.
void _data_bytes_free(u8* buf)
    {
    asm {
#if ARCH_6502
        LDA buf
        LDX buf+1
        ORA buf+1
        BEQ .dbf_done
        LDA buf
        LDX buf+1
#if XTC_POINTER_WIDTH == 3
        LDY buf+2
#elif XTC_POINTER_WIDTH == 4
        LDA buf+3
        STA $89
        LDA buf
        LDX buf+1
        LDY buf+2
#else
        LDY #heap_bank_first
#endif
        JSR _heap_free
.dbf_done:
#endif
    }
    }

class Data<Comparable, Hashable>
    {
    u8* _bytes;    // owned heap allocation
    u16 _length;   // number of valid bytes in _bytes
    u16 _capacity; // bytes allocated in _bytes

    void init(void)
        {
        _bytes = (u8*)0;
        _length = (u16)0;
        _capacity = (u16)0;
        }

    // Build from a source pointer + length, copying the bytes into
    // a fresh heap allocation.
    static Data* withBytes(u8* src, u16 len)
        {
        Data* d = new Data();
        u8* buf = new u8[len];
        for (u16 i = (u16)0; i < len; i++)
            {
            buf[i] = src[i];
            }
        d._bytes = buf;
        d._length = len;
        d._capacity = len;
        return d;
        }

    // RESERVE room for `len` bytes. The Data comes back EMPTY — length 0,
    // insert point at the front — so appending fills from byte 0 and does not
    // reallocate until `len` bytes have gone in.
    //
    // This used to allocate `len` zero-filled bytes and report a length of
    // `len`, which made `withCapacity(n)` followed by appends produce 2n bytes:
    // the reservation was itself valid-looking data. It was also the only
    // `withCapacity` in the library that behaved that way — Array, Set and Map
    // all reserve. Callers that want n zero bytes want `withLength`, below.
    static Data* withCapacity(u16 len)
        {
        Data* d = new Data();
        d._bytes = new u8[len];
        d._length = (u16)0;
        d._capacity = len;
        return d;
        }

    // `len` zero-filled bytes, ready to be written through `setByteAt`. This
    // is the sized-buffer constructor; `withCapacity` is the empty one.
    static Data* withLength(u16 len)
        {
        Data* d = new Data();
        u8* buf = new u8[len];
        for (u16 i = (u16)0; i < len; i++)
            {
            buf[i] = (u8)0;
            }
        d._bytes = buf;
        d._length = len;
        d._capacity = len;
        return d;
        }

    // ── Accessors ────────────────────────────────────────────────
    // Each subscript routes through a local copy of the heap pointer rather
    // than subscripting the ivar directly — the shape the banked-heap codegen
    // wants.
    u16 length(void)
        {
        return _length;
        }
    u8* bytes(void)
        {
        return _bytes;
        }
    u8 byteAt(u16 idx)
        {
        u8* b = _bytes;
        return b[idx];
        }
    void setByteAt(u16 idx, u8 value)
        {
        u8* b = _bytes;
        b[idx] = value;
        }

    bool isEmpty(void)
        {
        return _length == (u16)0;
        }

    // ── Destruction ──────────────────────────────────────────────
    // `_bytes` is a raw `u8*`, not a class pointer, so the automatic aggregate
    // walker does not reclaim it — a Data has to free it itself. It never did.
    void dealloc(void)
        {
        _data_bytes_free(_bytes);
        }

    // ── Building ─────────────────────────────────────────────────
    static Data* withData(Data* other)
        {
        if (other == 0)
            return Data.withCapacity((u16)0);
        return Data.withBytes(other.bytes(), other.length());
        }

    // Grow the buffer to hold `need` bytes, preserving what is there. A request
    // that already fits returns without touching the heap; the old version
    // reallocated on every appended byte, which is O(n²) over a build.
    //
    // Same curve as this build's String: double to 1 KB, then a kilobyte at a
    // time, because an xt heap block cannot span a bank (~12 KB).
    void _reserve(u16 need)
        {
        if (_bytes != (u8*)0 && need <= _capacity)
            return;

        u16 cap = (_capacity == (u16)0) ? (u16)16 : _capacity;
        while (cap < need)
            {
            u16 step = (cap < (u16)1024) ? cap : (u16)1024;
            u16 next = cap + step;
            // u16 wrap — take need
            if (next <= cap)
                {
                cap = need;
                break;
                }
            cap = next;
            }

        u8* fresh = new u8[cap];
        u8* old = _bytes;
        for (u16 i = (u16)0; i < _length; i = i + (u16)1)
            fresh[i] = old[i];
        _bytes = fresh;
        _capacity = cap;
        _data_bytes_free(old);
        }

    // Bytes allocated, not bytes used.
    u16 capacity(void)
        {
        return _capacity;
        }

    void reserve(u16 need)
        {
        _reserve(need);
        }

    // ── Mutation ─────────────────────────────────────────────────
    void appendByte(u8 b)
        {
        _reserve(_length + (u16)1);
        u8* d = _bytes;
        d[_length] = b;
        _length = _length + (u16)1;
        }

    void append(Data* other)
        {
        if (other == 0 || other.length() == (u16)0)
            return;
        u16 n = other.length();
        _reserve(_length + n);
        u8* d = _bytes;
        u8* s = other.bytes();
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            d[_length + i] = s[i];
        _length = _length + n;
        }

    void appendBytes(u8* src, u16 n)
        {
        if (n == (u16)0)
            return;
        _reserve(_length + n);
        u8* d = _bytes;
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            d[_length + i] = src[i];
        _length = _length + n;
        }

    // Grow by `n` zero bytes — NSMutableData's increaseLengthBy:. The bytes are
    // zeroed, not left as whatever the allocator had.
    void increaseLengthBy(u16 n)
        {
        if (n == (u16)0)
            return;
        _reserve(_length + n);
        u8* d = _bytes;
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            d[_length + i] = (u8)0;
        _length = _length + n;
        }

    // Truncate, or extend with zeroes.
    void setLength(u16 n)
        {
        if (n > _length)
            {
            increaseLengthBy(n - _length);
            return;
            }
        _length = n;
        }

    // ── String bridge ────────────────────────────────────────────
    // M1's byte/encoding bridge — dataUsingEncoding: one way, initWithData:
    // the other. BOTH directions live here rather than half of each on String,
    // because Data already imports String and the reverse import would make the
    // two files depend on each other.
    //
    // The bytes are the string's own, WITHOUT the trailing NUL: a Data is a
    // length-carrying blob and does not need a terminator, and Foundation's
    // dataUsingEncoding: does not include one either.
    static Data* withString(String* s)
        {
        if (s == 0)
            return Data.withCapacity((u16)0);
        return Data.withBytes(s.cString(), s.length());
        }

    // These bytes as text. An embedded NUL is copied like any other byte, so
    // `length()` stays right, but `cString()` on the result will stop there —
    // that is the C representation's limit, not this method's.
    String* stringValue(void)
        {
        return String.withBytes(_bytes, _length);
        }

    // ── Slicing ──────────────────────────────────────────────────
    // Out of range clamps to empty, as String's does.
    Data* subdata(u16 from, u16 len)
        {
        if (from >= _length)
            return Data.withCapacity((u16)0);
        u16 avail = _length - from;
        u16 n = (len < avail) ? len : avail;
        u8* b = _bytes;
        return Data.withBytes(&b[from], n);
        }

    Data* subdataFrom(u16 from)
        {
        if (from >= _length)
            return Data.withCapacity((u16)0);
        return subdata(from, _length - from);
        }

    // ── Search ───────────────────────────────────────────────────
    static u16 notFound(void)
        {
        return $FFFF;
        }

    u16 indexOfByte(u8 needle)
        {
        u8* b = _bytes;
        for (u16 i = (u16)0; i < _length; i = i + (u16)1)
            {
            if (b[i] == needle)
                return i;
            }
        return Data.notFound();
        }

    bool containsByte(u8 needle)
        {
        return indexOfByte(needle) != Data.notFound();
        }
    // ── Text ─────────────────────────────────────────────────────
    // Lowercase hex, no separators — "deadbeef". The representation you want
    // when a blob has to reach a log line or a comparison in a test.
    String* hexString(void)
        {
        String* out = String.withCString("");
        u8* b = _bytes;
        for (u16 i = (u32)0; i < _length; i = i + (u16)1)
            {
            u8 v = b[i];
            out.appendChar(Data._hexDigit(v >> (u8)4));
            out.appendChar(Data._hexDigit(v & (u8)$0F));
            }
        return out;
        }

    static u8 _hexDigit(u8 nibble)
        {
        if (nibble < (u8)10)
            return (u8)((u8)'0' + nibble);
        return (u8)((u8)'a' + (nibble - (u8)10));
        }

    // Object's description slot — `<Data 4: deadbeef>`.
    String* description(void)
        {
        String* out = String.withCString("<Data ");
        out.append(String.withU16(_length));
        out.appendCString(": ");
        out.append(hexString());
        out.appendChar((u8)'>');
        return out;
        }

    // ── Equality ────────────────────────────────────────────────
    bool equals(Data* other)
        {
        if (_length != other._length)
            return false;
        u8* a = _bytes;
        u8* b = other._bytes;
        for (u16 i = (u16)0; i < _length; i++)
            {
            if (a[i] != b[i])
                return false;
            }
        return true;
        }

    // Comparable protocol slot — heterogeneous collection helpers
    // call this through the vtable. Returns false on type mismatch.
    bool equals(Object* other)
        {
        Data* o = (Data* ?)other;
        if (o == 0)
            return false;
        return equals(o);
        }

    // ── Ordering ─────────────────────────────────────────────────
    // Lexicographic by unsigned byte, then by length — memcmp order. A shorter
    // buffer that is a prefix of a longer one sorts first.
    i8 compare(Data* other)
        {
        u8* a = _bytes;
        u8* b = other._bytes;
        u16 alen = _length;
        u16 blen = other._length;
        u16 n = (alen < blen) ? alen : blen;

        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            {
            u8 ca = a[i];
            u8 cb = b[i];
            if (ca < cb)
                return (i8)-1;
            if (ca > cb)
                return (i8)1;
            }
        if (alen < blen)
            return (i8)-1;
        if (alen > blen)
            return (i8)1;
        return (i8)0;
        }

    i8 compare(Object* other)
        {
        Data* o = (Data* ?)other;
        if (o == 0)
            return (i8)0;
        return compare(o);
        }

    // ── Hash ─────────────────────────────────────────────────────
    // Same XOR-rotate fold as String.hash() — distinct byte
    // sequences with the same multiset don't collapse, and equal
    // sequences (which compare equal under equals) produce the
    // same code by construction.
    u8 hash(void)
        {
        u8* b = _bytes;
        u8 h = (u8)0;
        for (u16 i = (u16)0; i < _length; i = i + (u16)1)
            {
            h = (u8)((h << 1) | (h >> 7)); // rotate left by 1
            h = h ^ b[i];
            }
        return h;
        }
    }
