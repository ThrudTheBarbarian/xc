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
//   Data* d = Data.withBytes(&raw[0], (u32)4);
//   for (u32 i = (u32)0; i < d.length(); i++)
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

#import "String.xc"
#import "Copying.xc"
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
    __arc_release((pointer)buf);
    }

class Data<Comparable, Hashable, Copying>
    {
    u8* _bytes;    // owned heap allocation
    u32 _length;   // number of valid bytes in _bytes
    u32 _capacity; // bytes allocated in _bytes

    void init(void)
        {
        _bytes = (u8*)0;
        _length = (u32)0;
        _capacity = (u32)0;
        }

    // Build from a source pointer + length, copying the bytes into
    // a fresh heap allocation.
    static Data* withBytes(u8* src, u32 len)
        {
        Data* d = new Data();
        u8* buf = new u8[len];
        for (u32 i = (u32)0; i < len; i++)
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
    static Data* withCapacity(u32 len)
        {
        Data* d = new Data();
        d._bytes = new u8[len];
        d._length = (u32)0;
        d._capacity = len;
        return d;
        }

    // `len` zero-filled bytes, ready to be written through `setByteAt`. This
    // is the sized-buffer constructor; `withCapacity` is the empty one.
    static Data* withLength(u32 len)
        {
        Data* d = new Data();
        u8* buf = new u8[len];
        for (u32 i = (u32)0; i < len; i++)
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
    u32 length(void)
        {
        return _length;
        }
    u8* bytes(void)
        {
        return _bytes;
        }
    u8 byteAt(u32 idx)
        {
        u8* b = _bytes;
        return b[idx];
        }
    void setByteAt(u32 idx, u8 value)
        {
        u8* b = _bytes;
        b[idx] = value;
        }

    bool isEmpty(void)
        {
        return _length == (u32)0;
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
            return Data.withCapacity((u32)0);
        return Data.withBytes(other.bytes(), other.length());
        }

    // Grow the buffer to hold `need` bytes, preserving what is there.
    //
    // Geometric — 16, then doubling — and a request that already fits returns
    // without touching the heap. The old version allocated, copied and freed on
    // every single appended byte, making appendByte O(n) and a built blob O(n²).
    void _reserve(u32 need)
        {
        if (_bytes != (u8*)0 && need <= _capacity)
            return;

        u32 cap = (_capacity == (u32)0) ? (u32)16 : _capacity;
        while (cap < need)
            {
            u32 next = cap * (u32)2;
            // width wrap — take need
            if (next <= cap)
                {
                cap = need;
                break;
                }
            cap = next;
            }

        u8* fresh = new u8[cap];
        u8* old = _bytes;
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
            fresh[i] = old[i];
        _bytes = fresh;
        _capacity = cap;
        _data_bytes_free(old);
        }

    // Bytes allocated, not bytes used.
    u32 capacity(void)
        {
        return _capacity;
        }

    void reserve(u32 need)
        {
        _reserve(need);
        }

    // ── Mutation ─────────────────────────────────────────────────
    void appendByte(u8 b)
        {
        _reserve(_length + (u32)1);
        u8* d = _bytes;
        d[_length] = b;
        _length = _length + (u32)1;
        }

    void append(Data* other)
        {
        if (other == 0 || other.length() == (u32)0)
            return;
        u32 n = other.length();
        _reserve(_length + n);
        u8* d = _bytes;
        u8* s = other.bytes();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            d[_length + i] = s[i];
        _length = _length + n;
        }

    void appendBytes(u8* src, u32 n)
        {
        if (n == (u32)0)
            return;
        _reserve(_length + n);
        u8* d = _bytes;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            d[_length + i] = src[i];
        _length = _length + n;
        }

    // Grow by `n` zero bytes — NSMutableData's increaseLengthBy:. The bytes are
    // zeroed, not left as whatever the allocator had.
    void increaseLengthBy(u32 n)
        {
        if (n == (u32)0)
            return;
        _reserve(_length + n);
        u8* d = _bytes;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            d[_length + i] = (u8)0;
        _length = _length + n;
        }

    // Truncate, or extend with zeroes.
    void setLength(u32 n)
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
            return Data.withCapacity((u32)0);
        return Data.withBytes(s.cString(), s.byteLength());
        }

    // These bytes as text. An embedded NUL is copied like any other byte, so
    // `length()` stays right, but `cString()` on the result will stop there —
    // that is the C representation's limit, not this method's.
    String* stringValue(void)
        {
        return String.withBytes(_bytes, _length);
        }

    // ── Encoding exports (private:docs/Design/string-utf8.md §4) ─────────
    // Encode a String outward as `enc` bytes. Lives HERE, not on String, for
    // the same reason withString does: Data already imports String, and the
    // reverse import is a cycle. (A cyclic #import used to silently corrupt
    // field offsets at -O2+; task #20 fixed that, but one importer per pair
    // is still the right structure.) A code point the target encoding cannot express
    // (Latin-1 above U+00FF, ASCII above U+007F) becomes '?' — the caller
    // chose the narrower world. ENC_UTF8 is a plain byte copy, including any
    // invalid bytes the String carries: export does not silently repair —
    // sanitizedUtf8() first if that is wanted.
    since("0.4") static Data* withStringEncoded(String* s, StrEncoding enc)
        {
        Data* out = new Data();
        if (s == 0)
            {
            return out;
            }
        out.reserve(s.byteLength());
        if (enc == ENC_UTF8)
            {
            u8* b = s.cString();
            u32 n = s.byteLength();
            u32 i = (u32)0;
            while (i < n)
                {
                out.appendByte(b[i]);
                i = i + (u32)1;
                }
            return out;
            }
        u32 i = (u32)0;
        while (i < s.byteLength())
            {
            u32 cp = s.charAtByte(i);
            i = s.nextCharByte(i);
            if (enc == ENC_ASCII || enc == ENC_LATIN1)
                {
                u32 cap = (enc == ENC_ASCII) ? (u32)0x7F : (u32)0xFF;
                if (cp > cap)
                    {
                    cp = (u32)'?';
                    }
                out.appendByte((u8)cp);
                continue;
                }
            // UTF-16, both orders; a pair above the BMP.
            if (cp >= (u32)0x10000)
                {
                u32 v = cp - (u32)0x10000;
                u32 hi = (u32)0xD800 + (v >> (u32)10);
                u32 lo = (u32)0xDC00 + (v & (u32)0x3FF);
                if (enc == ENC_UTF16LE)
                    {
                    out.appendByte((u8)(hi & (u32)0xFF));
                    out.appendByte((u8)(hi >> (u32)8));
                    out.appendByte((u8)(lo & (u32)0xFF));
                    out.appendByte((u8)(lo >> (u32)8));
                    }
                else
                    {
                    out.appendByte((u8)(hi >> (u32)8));
                    out.appendByte((u8)(hi & (u32)0xFF));
                    out.appendByte((u8)(lo >> (u32)8));
                    out.appendByte((u8)(lo & (u32)0xFF));
                    }
                continue;
                }
            if (enc == ENC_UTF16LE)
                {
                out.appendByte((u8)(cp & (u32)0xFF));
                out.appendByte((u8)(cp >> (u32)8));
                }
            else
                {
                out.appendByte((u8)(cp >> (u32)8));
                out.appendByte((u8)(cp & (u32)0xFF));
                }
            }
        return out;
        }

    // ── Slicing ──────────────────────────────────────────────────
    // Out of range clamps to empty, as String's does.
    Data* subdata(u32 from, u32 len)
        {
        if (from >= _length)
            return Data.withCapacity((u32)0);
        u32 avail = _length - from;
        u32 n = (len < avail) ? len : avail;
        u8* b = _bytes;
        return Data.withBytes(&b[from], n);
        }

    Data* subdataFrom(u32 from)
        {
        if (from >= _length)
            return Data.withCapacity((u32)0);
        return subdata(from, _length - from);
        }

    // ── Search ───────────────────────────────────────────────────
    static u32 notFound(void)
        {
        return $FFFFFFFF;
        }

    u32 indexOfByte(u8 needle)
        {
        u8* b = _bytes;
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
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
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
            {
            u8 v = b[i];
            out.appendByte(Data._hexDigit(v >> (u8)4));
            out.appendByte(Data._hexDigit(v & (u8)$0F));
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
        out.append(String.withU32(_length));
        out.appendCString(": ");
        out.append(hexString());
        out.appendByte((u8)'>');
        return out;
        }

    // ── Equality ────────────────────────────────────────────────
    bool equals(Data* other)
        {
        if (_length != other._length)
            return false;
        u8* a = _bytes;
        u8* b = other._bytes;
        for (u32 i = (u32)0; i < _length; i++)
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
        u32 alen = _length;
        u32 blen = other._length;
        u32 n = (alen < blen) ? alen : blen;

        for (u32 i = (u32)0; i < n; i = i + (u32)1)
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
    u32 hash(void)
        {
        // FNV-1a. Replaces a rotate-and-XOR fold into a u8, whose 256-value
        // range was the reason Map and Set could not grow past 256 slots.
        u8* b = _bytes;
        u32 h = (u32)2166136261;
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
            {
            h = h ^ (u32)b[i];
            h = h * (u32)16777619;
            }
        return h;
        }

    // <Copying>: an independent Data over the same bytes. Data owns its
    // buffer, so this duplicates it rather than sharing.
    Data* copy(void)
        {
        return Data.withData(self);
        }
    }
