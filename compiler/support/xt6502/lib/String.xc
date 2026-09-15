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

// String.xc — Object-style wrapper around a null-terminated u8*.
// =================================================================
//
// First step toward heterogeneous collections: a String holds a
// heap-owned u8* with a trailing `\0`, exposing length / charAt /
// equals helpers. A bare `string` (alias for `u8*`) covers the
// passing-strings-around use case in xtc today; this class adds the
// "stored as a class-instance value alongside other primitives"
// shape that container types will eventually need.
//
// Usage:
//   String* s = String.withCString("hello");
//   for (u16 i = (u16)0; i < s.length(); i++)
//       Stdio.printf("%c", s.charAt(i));
//
// Notes:
//   * The underlying buffer is allocated by the heap allocator and
//     released when the String is released — so this class only compiles on
//     heap-capable targets (the 6502 `xt` layouts, and every native backend).
//     A bump-only target rejects `new u8[N]`.
//
//   * `withCString(src)` copies `src` into a fresh heap buffer; the
//     caller's pointer can be a string literal or a pointer the
//     caller still owns.
//
//   * `cString()` returns the raw u8* for use with Stdio.printf
//     `%s` and similar APIs. It is a BORROW into the String's own
//     buffer, valid only until the String is next GROWN — any append
//     or insert may realloc and free the old bytes (private:docs/bugs/056).
//     `copyCString()` returns a heap copy the caller owns instead.

// String implicitly inherits from the runtime's built-in `Object`
// root class — see the matching note on Number.xc — so a String*
// fits anywhere an Object* is expected. Conforms to Comparable so
// heterogeneous collection helpers can compare strings through the
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

#import "Comparable.xc"
#import "CharacterSet.xc"
#import "Hashable.xc"
#import "Array.xc"

// Free a String's byte buffer. `new u8[N]` comes from the same allocator as any
// object — a heap header with refcount 1 and no destructor — so releasing it to
// zero reclaims it. Null-safe.
//
// This is the 6502 build: a raw buffer here carries no destructor descriptor,
// and the ARC release path dispatches one — so it goes straight to _heap_free.
void _string_bytes_free(u8* buf)
    {
    asm {
#if ARCH_6502
        LDA buf
        LDX buf+1
        ORA buf+1
        BEQ .sbf_done
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
.sbf_done:
#endif
    }
    }

class String<Comparable, Hashable>
    {
    u8* _bytes;    // owned heap allocation, includes trailing \0
    u16 _length;   // cached length (number of bytes before the \0)
    u16 _capacity; // bytes usable in _bytes EXCLUDING the trailing \0

    void init(void)
        {
        _bytes = (u8*)0;
        _length = (u16)0;
        _capacity = (u16)0;
        }

    // Build from a null-terminated source pointer (string literal,
    // existing buffer, etc). Bytes are copied into a fresh heap
    // allocation so the String owns its own storage.
    static String* withCString(u8* src)
        {
        String* s = new String();
        u16 len = String._cstringLen(src);
        u8* buf = new u8[len + (u16)1];
        for (u16 i = (u16)0; i <= len; i++)
            {
            buf[i] = src[i];
            }
        s._bytes = buf;
        s._length = len;
        s._capacity = len;
        return s;
        }

    // Length scanner — walks the source until the first \0 or 64 KB,
    // whichever comes first. The cap is the natural u16 limit;
    // an unterminated source past that point is a programming error
    // and the scanner returns $FFFF (max u16) as a clue.
    static u16 _cstringLen(u8* src)
        {
        u16 i = (u16)0;
        while (src[i] != (u8)0)
            {
            i = i + (u16)1;
            if (i == (u16)0)
                return $FFFF; // wrapped — unterminated
            }
        return i;
        }

    // ── Accessors ────────────────────────────────────────────────
    // Subscript reads route through a local copy of the heap pointer rather
    // than subscripting the ivar directly — the shape the banked-heap codegen
    // wants.
    u16 length(void)
        {
        return _length;
        }
    u8 charAt(u16 idx)
        {
        u8* b = _bytes;
        return b[idx];
        }
    // BORROW: a pointer into the String's own buffer, valid until the String
    // is next GROWN — append/appendChar/appendCString/appendFormat/insert may
    // realloc and free it, after which this pointer dangles (and usually
    // still appears to work, which is the failure that survives testing —
    // private:docs/bugs/056). Copy with copyCString() if the bytes must outlive the
    // next mutation.
    u8* cString(void)
        {
        // NEVER null. An empty String carries no buffer at all — `init` leaves
        // `_bytes` at 0 — so this used to hand back a null pointer that the
        // caller immediately walked: `printf("%s", s.cString())` on an empty
        // String was a segfault inside _cstringLen, at address 0, with no
        // frame to name the culprit. Allocating the terminator on demand keeps
        // the borrow pointing into the String's OWN buffer (a shared static ""
        // would let one caller's write corrupt every other empty String) and
        // costs one byte, once, only for a String somebody actually asks to
        // read as C.
        if (_bytes == (u8*)0)
            {
            u8* buf = new u8[(u32)1];
            buf[(u32)0] = (u8)0;
            _bytes = buf;
            _capacity = (u32)0;
            }
        return _bytes;
        }

    // A NUL-terminated heap COPY of the bytes that the caller owns and frees
    // with `delete`. The safe form of cString() for a keeper: nothing the
    // String later does can invalidate it.
    u8* copyCString(void)
        {
        u8* out = new u8[_length + (u16)1];
        u8* b = _bytes;
        for (u16 i = (u16)0; i < _length; i = i + (u16)1)
            out[i] = b[i];
        out[_length] = (u8)0;
        return out;
        }

    // ── Equality ────────────────────────────────────────────────
    // Byte-by-byte compare. Mismatched lengths shortcut to false.
    bool equals(String* other)
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
        String* o = (String* ?)other;
        if (o == 0)
            return false;
        return equals(o);
        }

    // ── Ordering ─────────────────────────────────────────────────
    // Lexicographic by byte value, then by length — the usual strcmp order, and
    // what Foundation's `compare:` gives you for ASCII. Returns < 0 / 0 / > 0.
    //
    // Bytes are compared UNSIGNED, so this orders by code point for ASCII and
    // by raw byte above 127. A shorter string that is a prefix of a longer one
    // sorts first ("go" before "gone").
    i8 compare(String* other)
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
        // Common prefix — the shorter one sorts first.
        if (alen < blen)
            return (i8)-1;
        if (alen > blen)
            return (i8)1;
        return (i8)0;
        }

    i8 compare(Object* other)
        {
        String* o = (String* ?)other;
        if (o == 0)
            return (i8)0;
        return compare(o);
        }

    // ── Hash ─────────────────────────────────────────────────────
    // XOR-fold every byte of the string (excluding the trailing \0
    // since two equal strings are guaranteed to share both content
    // and length). Pearson-style: each byte rotates the running
    // accumulator before the XOR so re-orderings of the same byte
    // multiset don't all collapse to the same code. Distribution
    // is good enough for typical key shapes; degenerate inputs
    // (long runs of identical bytes) are tolerated by the probe
    // chain.
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

    // ── Destruction ──────────────────────────────────────────────
    // `_bytes` is a raw `u8*`, not a class pointer, so the automatic aggregate
    // walker does not reclaim it — a String has to free it itself. It never
    // did: 300,000 Strings leaked 90 MB.
    void dealloc(void)
        {
        _string_bytes_free(_bytes);
        }

    // ── Building ─────────────────────────────────────────────────
    // A copy of another String.
    static String* withString(String* other)
        {
        if (other == 0)
            return String.withCString("");
        return String.withCString(other.cString());
        }

    // A String of `n` bytes taken from `src` — no NUL needed in the source.
    static String* withBytes(u8* src, u16 n)
        {
        String* s = new String();
        u8* buf = new u8[n + (u16)1];
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            buf[i] = src[i];
        buf[n] = (u8)0;
        s._bytes = buf;
        s._length = n;
        s._capacity = n;
        return s;
        }

    bool isEmpty(void)
        {
        return _length == (u16)0;
        }
    // ── Numbers as text ──────────────────────────────────────────
    // The conversion every program needs and none of them should write. Note
    // the digits come out in reverse and are then emitted forwards — the usual
    // shape, and the reason for the small scratch buffer.
    static String* withU32(u32 v)
        {
        String* s = String.withCString("");
        if (v == (u32)0)
            {
            s.appendChar((u8)'0');
            return s;
            }

        u8 tmp[10]; // u32 max is 4294967295 — 10 digits
        u8 n = (u8)0;
        while (v > (u32)0)
            {
            tmp[n] = (u8)((u32)'0' + (v % (u32)10));
            v = v / (u32)10;
            n = n + (u8)1;
            }
        while (n > (u8)0)
            {
            n = n - (u8)1;
            s.appendChar(tmp[n]);
            }
        return s;
        }

    static String* withI32(i32 v)
        {
        if (v >= (i32)0)
            return String.withU32((u32)v);
        String* s = String.withCString("-");
        // Negate in u32 so i32-min doesn't overflow on the way.
        u32 m = (u32)0 - (u32)v;
        s.append(String.withU32(m));
        return s;
        }

    static String* withI16(i16 v)
        {
        return String.withI32((i32)v);
        }
    static String* withU16(u16 v)
        {
        return String.withU32((u32)v);
        }

    // 64-bit, the same shape one width up.
    //
    // These exist because `appendFormat` cannot render one: it understands a
    // single `l`, so `%ld` is 32 bits and there is no `%lld` — and that is the
    // language's printf width contract, not an oversight. A caller that has a
    // 64-bit value and needs its text asks for it directly.
    static String* withU64(u64 v)
        {
        String* s = String.withCString("");
        if (v == (u64)0)
            {
            s.appendChar((u8)'0');
            return s;
            }

        u8 tmp[20]; // u64 max is 20 digits
        u8 n = (u8)0;
        while (v > (u64)0)
            {
            tmp[n] = (u8)((u64)'0' + (v % (u64)10));
            v = v / (u64)10;
            n = n + (u8)1;
            }
        while (n > (u8)0)
            {
            n = n - (u8)1;
            s.appendChar(tmp[n]);
            }
        return s;
        }

    static String* withI64(i64 v)
        {
        if (v >= (i64)0)
            return String.withU64((u64)v);
        String* s = String.withCString("-");
        // Negate in u64 so i64-min does not overflow on the way.
        u64 m = (u64)0 - (u64)v;
        s.append(String.withU64(m));
        return s;
        }

    // Fixed 3-decimal-place rendering. Deliberately not a general float
    // formatter — it is honest about what it does rather than pretending to
    // round-trip.
    // Render `f` with `precision` decimal places. 6 is the default — it matches
    // C's printf %f and Stdio.printf, so a float formatted through
    // String.withFloat, appendFormat("%f") or Stdio.printf("%f") all agree.
    // (It was 3, which made appendFormat's %f differ from Stdio's.)
    //
    // Note a 32-bit float carries roughly 7 significant digits, so the last
    // place or two at 6dp is not always meaningful — this matches C's behaviour
    // rather than promising accuracy the type does not have.
    static String* withFloat(float f, u8 precision)
        {
        String* s = String.withCString("");
        bool neg = f < 0.0;
        if (neg)
            f = 0.0 - f;
        i32 ip = (i32)f;
        float frac = f - (float)ip;
        float scale = 1.0;
        for (u8 d = (u8)0; d < precision; d = d + (u8)1)
            scale = scale * 10.0;
        i32 fp = (i32)(frac * scale);
        if (neg)
            s.appendChar((u8)'-');
        s.append(String.withI32((i32)ip));
        s.appendChar((u8)'.');
        // leading zeros inside the fraction
        i32 probe = (i32)scale / (i32)10;
        while (probe > (i32)1 && fp < probe)
            {
            s.appendChar((u8)'0');
            probe = probe / (i32)10;
            }
        s.append(String.withI32((i32)fp));
        return s;
        }

    static String* withFloat(float f)
        {
        return String.withFloat(f, (u8)6);
        }

    // Object's description slot: a String describes itself.
    String* description(void)
        {
        return String.withString(self);
        }

    // Grow the buffer so it can hold `need` bytes plus the NUL. Only called by
    // the mutating paths; a String built and never appended to pays nothing.
    //
    // A request that already fits returns without touching the heap. This used
    // to allocate, copy and free on EVERY appended byte, making appendChar O(n)
    // and an n-byte string O(n²) — and on a 1.79 MHz 8-bit CPU that is the
    // difference between a program finishing and a program appearing to hang.
    //
    // The growth curve is DELIBERATELY not the generic build's pure doubling:
    // it doubles up to 1 KB and then grows a kilobyte at a time. A single xt
    // heap block cannot span a bank (~12 KB ceiling), so doubling past 8 KB
    // would ask for 16 KB and fail an allocation that the exact-fit version
    // would have served — and 1 KB of slack is already a lot of RAM here.
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

        u8* fresh = new u8[cap + (u16)1];
        u8* old = _bytes;
        for (u16 i = (u16)0; i < _length; i = i + (u16)1)
            fresh[i] = old[i];
        fresh[_length] = (u8)0;
        _bytes = fresh;
        _capacity = cap;
        _string_bytes_free(old);
        }

    // Bytes allocated, not bytes used. Exposed for tests and for a caller that
    // wants to pre-size before a long run of appends.
    u16 capacity(void)
        {
        return _capacity;
        }

    void reserve(u16 need)
        {
        _reserve(need);
        }

    // ── Mutation ─────────────────────────────────────────────────
    // `append` mutates the receiver; `appending` returns a new String and
    // leaves the receiver alone. Same pair as Foundation's
    // appendString: / stringByAppendingString:.
    void append(String* other)
        {
        if (other == 0 || other.length() == (u16)0)
            return;
        u16 n = other.length();
        _reserve(_length + n);
        u8* dst = _bytes;
        u8* src = other.cString();
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            dst[_length + i] = src[i];
        _length = _length + n;
        dst[_length] = (u8)0;
        }

    void appendCString(u8* src)
        {
        append(String.withCString(src));
        }

    void appendChar(u8 ch)
        {
        _reserve(_length + (u16)1);
        u8* dst = _bytes;
        dst[_length] = ch;
        _length = _length + (u16)1;
        dst[_length] = (u8)0;
        }

    // `n` bytes from a raw pointer — no NUL needed, and the bytes may be
    // anything including zero. The counterpart of String.withBytes, and what
    // lets the search/replace paths copy a slice without allocating a temporary
    // String for it.
    //
    // `src` must NOT point into this String's own buffer: appending may
    // reallocate and free it. Splice a String into itself with insert /
    // replaceRange, which handle that case.
    void appendBytes(u8* src, u16 n)
        {
        if (n == (u16)0)
            return;
        _reserve(_length + n);
        u8* dst = _bytes;
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            dst[_length + i] = src[i];
        _length = _length + n;
        dst[_length] = (u8)0;
        }

    String* appending(String* other)
        {
        String* out = String.withString(self);
        out.append(other);
        return out;
        }

    // ── Splicing ─────────────────────────────────────────────────
    // The NSMutableString surface M1 found missing: String grew and appended,
    // but it could not splice. Everything below routes through `_splice`.
    //
    // `_splice(at, remove, src, srcLen)` replaces `remove` bytes at `at` with
    // `srcLen` bytes from `src`, in place. `at` and `remove` are CLAMPED rather
    // than rejected — past the end is an empty edit, the same choice the
    // slicing methods make.
    //
    // `src` must not point into this String's own buffer: the reserve below can
    // reallocate and free it. Every public caller either passes a foreign
    // buffer or copies first (see `insert` / `replaceRange`).
    void _splice(u16 at, u16 remove, u8* src, u16 srcLen)
        {
        if (at > _length)
            at = _length;
        u16 avail = _length - at;
        if (remove > avail)
            remove = avail;

        u16 newLen = _length - remove + srcLen;
        _reserve(newLen);
        u8* b = _bytes;

        if (srcLen > remove)
            {
            // Growing: shift the tail right, walking backwards so the
            // overlapping copy doesn't overwrite what it has yet to read.
            u16 delta = srcLen - remove;
            u16 i = _length;
            while (i > at + remove)
                {
                b[i - (u16)1 + delta] = b[i - (u16)1];
                i = i - (u16)1;
                }
            }
        else if (srcLen < remove)
            {
            // Shrinking: shift the tail left, forwards.
            u16 delta = remove - srcLen;
            for (u16 i = at + remove; i < _length; i = i + (u16)1)
                b[i - delta] = b[i];
            }

        for (u16 i = (u16)0; i < srcLen; i = i + (u16)1)
            b[at + i] = src[i];
        _length = newLen;
        b[newLen] = (u8)0;
        }

    // Insert `other` before index `at`. `at == length()` is `append`.
    void insert(u16 at, String* other)
        {
        if (other == 0 || other.length() == (u16)0)
            return;
        // Inserting a String into ITSELF would read from a buffer the splice
        // may already have freed — take a copy of the source first.
        if (other == self)
            {
            String* dup = String.withString(self);
            _splice(at, (u16)0, dup.cString(), dup.length());
            return;
            }
        _splice(at, (u16)0, other.cString(), other.length());
        }

    void insertCString(u16 at, u8* src)
        {
        _splice(at, (u16)0, src, String._cstringLen(src));
        }

    void insertChar(u16 at, u8 ch)
        {
        u8 one[1];
        one[0] = ch;
        _splice(at, (u16)0, &one[0], (u16)1);
        }

    // Remove `len` bytes at `at` — Foundation's deleteCharactersInRange:.
    void deleteRange(u16 at, u16 len)
        {
        _splice(at, len, (u8*)0, (u16)0);
        }

    // Replace `len` bytes at `at` with `other` — replaceCharactersInRange:.
    void replaceRange(u16 at, u16 len, String* other)
        {
        if (other == 0)
            {
            deleteRange(at, len);
            return;
            }
        if (other == self)
            {
            String* dup = String.withString(self);
            _splice(at, len, dup.cString(), dup.length());
            return;
            }
        _splice(at, len, other.cString(), other.length());
        }

    // Discard the contents, KEEP the buffer. A String reused as a scratch
    // accumulator — the emitter idiom — then costs one allocation, not one per
    // round.
    void clear(void)
        {
        _length = (u16)0;
        u8* b = _bytes;
        if (b != (u8*)0)
            b[0] = (u8)0;
        }

    // Become `other` — Foundation's setString:. Reuses the buffer.
    void setTo(String* other)
        {
        if (other == self)
            return;
        clear();
        append(other);
        }

    void setCString(u8* src)
        {
        clear();
        appendCString(src);
        }

    // In-place replaceOccurrencesOfString:. Returns how many were replaced,
    // as Foundation does. The non-mutating twin is `replacing`.
    //
    // The scan resumes AFTER the substitution, so a replacement containing the
    // needle ("a" → "aa") terminates instead of looping forever.
    u16 replaceOccurrences(String* find, String* sub)
        {
        if (find == 0)
            return (u16)0;
        u16 flen = find.length();
        if (flen == (u16)0 || flen > _length)
            return (u16)0;

        // A substitution string that IS this String would dangle across the
        // first splice; and a needle that is this String stops matching the
        // moment the first splice edits it. Copy both.
        String* needle = (find == self) ? String.withString(self) : find;
        String* repl = (sub == self) ? String.withString(self) : sub;
        u16 slen = (repl == 0) ? (u16)0 : repl.length();

        u16 n = (u16)0;
        u16 i = (u16)0;
        while (i + flen <= _length)
            {
            if (_matchesAt(i, needle))
                {
                _splice(i, flen, (slen == (u16)0) ? (u8*)0 : repl.cString(), slen);
                i = i + slen;
                n = n + (u16)1;
                }
            else
                {
                i = i + (u16)1;
                }
            }
        return n;
        }

    // ── Search ───────────────────────────────────────────────────
    // Byte index of the first occurrence, or String.notFound().
    static u16 notFound(void)
        {
        return $FFFF;
        }

    u16 indexOfChar(u8 ch)
        {
        u8* b = _bytes;
        for (u16 i = (u16)0; i < _length; i = i + (u16)1)
            {
            if (b[i] == ch)
                return i;
            }
        return String.notFound();
        }

    u16 lastIndexOfChar(u8 ch)
        {
        u8* b = _bytes;
        u16 i = _length;
        while (i > (u16)0)
            {
            i = i - (u16)1;
            if (b[i] == ch)
                return i;
            }
        return String.notFound();
        }

    // Does `needle` sit at exactly `at`? The primitive under both the search
    // and the in-place replace, neither of which should allocate to ask.
    bool _matchesAt(u16 at, String* needle)
        {
        if (needle == 0)
            return false;
        u16 n = needle.length();
        if (at + n > _length)
            return false;
        u8* h = _bytes;
        u8* p = needle.cString();
        for (u16 j = (u16)0; j < n; j = j + (u16)1)
            {
            if (h[at + j] != p[j])
                return false;
            }
        return true;
        }

    // Naive substring search. Fine for the string lengths a UI deals in; if a
    // hot path ever needs better, this is the one place to change.
    u16 indexOf(String* needle)
        {
        return indexOf(needle, (u16)0);
        }

    // The same search starting at `from` — what a scanning loop wants, and
    // what stops `replacing` allocating a fresh substring per iteration just to
    // ask "where is the next one".
    u16 indexOf(String* needle, u16 from)
        {
        if (needle == 0)
            return String.notFound();
        u16 n = needle.length();
        if (from > _length)
            return String.notFound();
        if (n == (u16)0)
            return from; // empty needle matches at `from`
        if (from + n > _length)
            return String.notFound();

        u16 last = _length - n;
        for (u16 i = from; i <= last; i = i + (u16)1)
            {
            if (_matchesAt(i, needle))
                return i;
            }
        return String.notFound();
        }

    bool contains(String* needle)
        {
        return indexOf(needle) != String.notFound();
        }

    bool hasPrefix(String* p)
        {
        if (p == 0)
            return false;
        u16 n = p.length();
        if (n > _length)
            return false;
        u8* a = _bytes;
        u8* b = p.cString();
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            {
            if (a[i] != b[i])
                return false;
            }
        return true;
        }

    bool hasSuffix(String* s)
        {
        if (s == 0)
            return false;
        u16 n = s.length();
        if (n > _length)
            return false;
        u8* a = _bytes;
        u8* b = s.cString();
        u16 off = _length - n;
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            {
            if (a[off + i] != b[i])
                return false;
            }
        return true;
        }

    // ── Slicing ──────────────────────────────────────────────────
    // `from` past the end yields an empty String; a length past the end is
    // clamped. Out-of-range is not an error, it is an empty result — the same
    // choice Foundation makes for a clamped range.
    String* substringFrom(u16 from)
        {
        if (from >= _length)
            return String.withCString("");
        return String.withBytes(_bytesAt(from), _length - from);
        }

    String* substring(u16 from, u16 len)
        {
        if (from >= _length)
            return String.withCString("");
        u16 avail = _length - from;
        u16 n = (len < avail) ? len : avail;
        return String.withBytes(_bytesAt(from), n);
        }

    String* substringTo(u16 to)
        {
        return substring((u16)0, to);
        }

    u8* _bytesAt(u16 off)
        {
        u8* b = _bytes;
        return &b[off];
        }

    // ── Bytes ────────────────────────────────────────────────────
    // The getBytes: / lengthOfBytesUsingEncoding: half of M1's byte/encoding
    // bridge. The Data half lives on Data (Data.withString / stringValue),
    // because Data already imports String and putting it here would make the
    // two files import each other.
    //
    // Copy up to `max` bytes into `dst` and return how many were copied. NO
    // trailing NUL is written — `max` is the size of the destination and all of
    // it is available for content, which is what Foundation's getBytes: does.
    // A caller that wants a C string should ask for `max - 1` and terminate.
    u16 getBytes(u8* dst, u16 max)
        {
        if (dst == (u8*)0)
            return (u16)0;
        u16 n = (max < _length) ? max : _length;
        u8* b = _bytes;
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            dst[i] = b[i];
        return n;
        }

    // The same as length(): this class stores bytes, and an xtc `string` is
    // UTF-8 by convention, so a byte count and a length are the same number.
    // Present under its own name because a call site asking about BYTES is
    // making a different assumption than one asking about characters, and one
    // of them will matter the day a non-ASCII encoding shows up.
    u16 byteLength(void)
        {
        return _length;
        }

    // ── Case ─────────────────────────────────────────────────────
    // ASCII only, which is what the whole class assumes.
    String* uppercased(void)
        {
        String* out = String.withString(self);
        u8* b = out.cString();
        for (u16 i = (u16)0; i < _length; i = i + (u16)1)
            {
            u8 c = b[i];
            if (c >= (u8)'a' && c <= (u8)'z')
                b[i] = c - (u8)32;
            }
        return out;
        }

    String* lowercased(void)
        {
        String* out = String.withString(self);
        u8* b = out.cString();
        for (u16 i = (u16)0; i < _length; i = i + (u16)1)
            {
            u8 c = b[i];
            if (c >= (u8)'A' && c <= (u8)'Z')
                b[i] = c + (u8)32;
            }
        return out;
        }

    // Order ignoring ASCII case — Foundation's caseInsensitiveCompare:.
    i8 caseInsensitiveCompare(String* other)
        {
        if (other == 0)
            return (i8)0;
        return lowercased().compare(other.lowercased());
        }

    bool equalsIgnoringCase(String* other)
        {
        return caseInsensitiveCompare(other) == (i8)0;
        }

    // ── Whitespace ───────────────────────────────────────────────
    static bool _isSpace(u8 c)
        {
        return c == (u8)32 || c == (u8)9 || c == (u8)10 || c == (u8)13;
        }

    String* trimmed(void)
        {
        u8* b = _bytes;
        u16 lo = (u16)0;
        while (lo < _length && String._isSpace(b[lo]))
            lo = lo + (u16)1;
        u16 hi = _length;
        while (hi > lo && String._isSpace(b[hi - (u16)1]))
            hi = hi - (u16)1;
        return substring(lo, hi - lo);
        }

    // ── Character-set search ─────────────────────────────────────
    // rangeOfCharacterFromSet: / componentsSeparatedByCharactersInSet: /
    // stringByTrimmingCharactersInSet: — the methods M1 said needed "a
    // character-set notion xtc lacks entirely". CharacterSet.xc is that notion:
    // a 256-bit bitmap, so each test below is a shift and an AND.
    //
    // A null set matches nothing, which makes every method here degrade to the
    // no-op answer rather than to a fault.
    u16 indexOfCharacterFrom(CharacterSet* set)
        {
        if (set == 0)
            return String.notFound();
        u8* b = _bytes;
        for (u16 i = (u16)0; i < _length; i = i + (u16)1)
            {
            if (set.contains(b[i]))
                return i;
            }
        return String.notFound();
        }

    u16 lastIndexOfCharacterFrom(CharacterSet* set)
        {
        if (set == 0)
            return String.notFound();
        u8* b = _bytes;
        u16 i = _length;
        while (i > (u16)0)
            {
            i = i - (u16)1;
            if (set.contains(b[i]))
                return i;
            }
        return String.notFound();
        }

    bool containsCharacterFrom(CharacterSet* set)
        {
        return indexOfCharacterFrom(set) != String.notFound();
        }

    // Trim any leading and trailing bytes in `set`. The no-argument `trimmed()`
    // is the same operation over whitespace-and-newlines, kept as its own
    // implementation because it is the common case and needs no set built.
    String* trimmed(CharacterSet* set)
        {
        if (set == 0)
            return String.withString(self);
        u8* b = _bytes;
        u16 lo = (u16)0;
        while (lo < _length && set.contains(b[lo]))
            lo = lo + (u16)1;
        u16 hi = _length;
        while (hi > lo && set.contains(b[hi - (u16)1]))
            hi = hi - (u16)1;
        return substring(lo, hi - lo);
        }

    // Split on ANY byte in the set — componentsSeparatedByCharactersInSet:.
    // Consecutive separators still yield empty components, exactly as the
    // single-byte `split` does, because a CSV depends on it.
    Array* split(CharacterSet* set)
        {
        Array* parts = new Array();
        if (set == 0)
            {
            parts.add(String.withString(self));
            return parts;
            }
        u8* b = _bytes;
        u16 start = (u16)0;
        for (u16 i = (u16)0; i < _length; i = i + (u16)1)
            {
            if (set.contains(b[i]))
                {
                parts.add(substring(start, i - start));
                start = i + (u16)1;
                }
            }
        parts.add(substring(start, _length - start));
        return parts;
        }

    // This string's characters AS a set — characterSetWithCharactersInString:.
    // It lives here rather than on CharacterSet so that CharacterSet needs no
    // import of String: String imports CharacterSet, and two library files that
    // import each other is a cycle.
    CharacterSet* asCharacterSet(void)
        {
        return CharacterSet.withCString(_bytes);
        }

    // ── Splitting and joining ────────────────────────────────────
    // `split` on a byte separator, Foundation's componentsSeparatedByString: in
    // spirit. Consecutive separators yield empty components, and so do leading
    // and trailing ones — "a,,b" is three parts, ",a" is two. That is the
    // behaviour a CSV parser needs; a caller who wants tokens rather than
    // fields can filter the empties out.
    Array* split(u8 sep)
        {
        Array* parts = new Array();
        u8* b = _bytes;
        u16 start = (u16)0;
        for (u16 i = (u16)0; i < _length; i = i + (u16)1)
            {
            if (b[i] == sep)
                {
                parts.add(substring(start, i - start));
                start = i + (u16)1;
                }
            }
        parts.add(substring(start, _length - start));
        return parts;
        }

    // Join an Array of Strings with a separator. Non-String elements are
    // skipped rather than stringified — this is not a formatter.
    static String* join(Array* parts, String* sep)
        {
        String* out = String.withCString("");
        if (parts == 0)
            return out;
        bool first = true;
        for (u16 i = (u16)0; i < parts.count(); i = i + (u16)1)
            {
            String* p = (String* ?)parts.get(i);
            if (p == 0)
                continue;
            if (!first && sep != 0)
                out.append(sep);
            out.append(p);
            first = false;
            }
        return out;
        }

    // Every occurrence of `find` replaced by `sub`. An empty `find` returns a
    // copy rather than looping forever.
    //
    // Scans with the offset form of indexOf and copies slices with appendBytes.
    // The first version built a fresh substringFrom(i) — a whole copy of the
    // remaining text — on every iteration, so replacing k needles in an n-byte
    // string allocated O(k) strings totalling O(k·n) bytes. On a 12 KB bank
    // that is not just slow, it is a failed allocation.
    String* replacing(String* find, String* sub)
        {
        if (find == 0 || find.length() == (u16)0)
            return String.withString(self);

        String* out = String.withCString("");
        u16 n = find.length();
        u16 i = (u16)0;
        while (i < _length)
            {
            u16 at = indexOf(find, i);
            if (at == String.notFound())
                {
                out.appendBytes(_bytesAt(i), _length - i);
                i = _length;
                }
            else
                {
                out.appendBytes(_bytesAt(i), at - i);
                if (sub != 0)
                    out.append(sub);
                i = at + n;
                }
            }
        return out;
        }

    // ── Paths ────────────────────────────────────────────────────
    // The stringByAppendingPathComponent: / …PathExtension: family. Small,
    // self-contained, and needed by every part of a compiler that touches a
    // filename — which is most of the driver.
    //
    // The separator is '/' on every target: the xt targets have no filesystem
    // of their own, and the hosted ones are POSIX. Windows accepts '/' in every
    // API that takes a path, so win64 needs no second rule here.
    //
    // Semantics follow Foundation, including its edge cases: trailing
    // separators are ignored when finding the last component, a leading '.' is
    // NOT an extension (".bashrc" has none), and the root "/" is its own last
    // component and its own parent.
    static u8 pathSeparator(void)
        {
        return (u8)'/';
        }

    // One past the last non-separator byte — i.e. the end of the last
    // component, with any trailing '/' ignored.
    u16 _lastComponentEnd(void)
        {
        u8* b = _bytes;
        u16 end = _length;
        while (end > (u16)0 && b[end - (u16)1] == String.pathSeparator())
            end = end - (u16)1;
        return end;
        }

    // Index of the first byte of the component ending at `end`.
    u16 _lastComponentStart(u16 end)
        {
        u8* b = _bytes;
        u16 start = end;
        while (start > (u16)0 && b[start - (u16)1] != String.pathSeparator())
            start = start - (u16)1;
        return start;
        }

    bool isAbsolutePath(void)
        {
        if (_length == (u16)0)
            return false;
        u8* b = _bytes;
        return b[0] == String.pathSeparator();
        }

    String* lastPathComponent(void)
        {
        u16 end = _lastComponentEnd();
        // Nothing but separators: the root is its own last component.
        if (end == (u16)0)
            return (_length == (u16)0) ? String.withCString("") : String.withCString("/");
        u16 start = _lastComponentStart(end);
        return substring(start, end - start);
        }

    String* deletingLastPathComponent(void)
        {
        u16 end = _lastComponentEnd();
        if (end == (u16)0)
            return (_length == (u16)0) ? String.withCString("") : String.withCString("/");

        u16 start = _lastComponentStart(end);
        // Separators BETWEEN the parent and this component belong to neither.
        u8* b = _bytes;
        u16 cut = start;
        while (cut > (u16)0 && b[cut - (u16)1] == String.pathSeparator())
            cut = cut - (u16)1;

        if (cut == (u16)0)
            {
            // "/usr" → "/" (absolute), "usr" → "" (relative).
            return (start > (u16)0) ? String.withCString("/") : String.withCString("");
            }
        return substring((u16)0, cut);
        }

    // Index of the '.' introducing the last component's extension, or
    // notFound(). A dot that STARTS the component (".bashrc") or ENDS it
    // ("archive.") introduces nothing.
    u16 _extensionDot(void)
        {
        u16 end = _lastComponentEnd();
        if (end == (u16)0)
            return String.notFound();
        u16 start = _lastComponentStart(end);
        u8* b = _bytes;
        u16 i = end;
        while (i > start)
            {
            i = i - (u16)1;
            if (b[i] == (u8)'.')
                {
                if (i == start)
                    return String.notFound(); // ".bashrc"
                if (i + (u16)1 >= end)
                    return String.notFound(); // "archive."
                return i;
                }
            }
        return String.notFound();
        }

    String* pathExtension(void)
        {
        u16 dot = _extensionDot();
        if (dot == String.notFound())
            return String.withCString("");
        u16 end = _lastComponentEnd();
        return substring(dot + (u16)1, end - dot - (u16)1);
        }

    String* deletingPathExtension(void)
        {
        u16 dot = _extensionDot();
        if (dot == String.notFound())
            return String.withString(self);
        return substring((u16)0, dot);
        }

    // "a" + "b" → "a/b", with exactly one separator however many either side
    // brings. An empty receiver yields the component alone, so a loop can start
    // from "" and keep joining.
    String* appendingPathComponent(String* component)
        {
        u16 end = _lastComponentEnd(); // receiver, trailing '/' gone
        String* base = substring((u16)0, end);

        u16 skip = (u16)0;
        if (component != 0)
            {
            while (skip < component.length() && component.charAt(skip) == String.pathSeparator())
                skip = skip + (u16)1;
            }
        String* tail = (component == 0) ? String.withCString("")
                                        : component.substringFrom(skip);
        // Its own trailing separators go too, so the result never ends in one.
        while (tail.length() > (u16)0 && tail.charAt(tail.length() - (u16)1) == String.pathSeparator())
            tail.deleteRange(tail.length() - (u16)1, (u16)1);

        if (tail.isEmpty())
            {
            if (!base.isEmpty())
                return base;
            return (_length == (u16)0) ? String.withCString("")
                                       : String.withCString("/");
            }
        if (base.isEmpty())
            {
            // The receiver was empty (relative) or all separators (root).
            if (_length == (u16)0)
                return tail;
            String* abs = String.withCString("/");
            abs.append(tail);
            return abs;
            }
        base.appendChar(String.pathSeparator());
        base.append(tail);
        return base;
        }

    // "file" + "txt" → "file.txt". An empty extension is a copy, not a
    // trailing dot.
    String* appendingPathExtension(String* ext)
        {
        u16 end = _lastComponentEnd();
        String* out = substring((u16)0, end);
        if (ext == 0 || ext.isEmpty())
            return out;
        out.appendChar((u8)'.');
        out.append(ext);
        return out;
        }

    // ── Buffer-building primitives ───────────────────────────────
    // These take a heap-owned u8* working buffer + a cursor and
    // emit at buf[cursor..]; the caller is responsible for sizing
    // the buffer. We avoid `u8 buf[N]` stack arrays here because
    // xt6502 SP-frame budgets are tight (119-byte cap, STACK-ABI
    // §7) and a 64-byte locals slot for a single description() body
    // pushes class methods over the wall.

    // Append a NUL-terminated source to `buf[cursor..]`, return
    // the new cursor. Used by _classDescribe for the class name
    // (and could be reused by user description() overrides).
    static u8 _appendCStr(u8* buf, u8 cursor, u8* src)
        {
        u8 i = (u8)0;
        while (src[i] != (u8)0)
            {
            buf[cursor + i] = src[i];
            i = i + (u8)1;
            }
        return cursor + i;
        }

    // Append `val`'s decimal representation to `buf[cursor..]`,
    // return the new cursor. u16 max is 65535 (5 digits). The
    // 5-byte reverse scratch lives on the SP frame, well under
    // the per-function budget. Synthesised description() bodies
    // widen narrower ivars (u8 / i8 / i16) to u16 on the way in,
    // so this is the only decimal helper most call sites need.
    static u8 _appendU16(u8* buf, u8 cursor, u16 val)
        {
        if (val == (u16)0)
            {
            buf[cursor] = (u8)'0';
            return cursor + (u8)1;
            }
        u8 tmp[5];
        u8 n = (u8)0;
        while (val > (u16)0)
            {
            tmp[n] = (u8)((u16)'0' + (val % (u16)10));
            val = val / (u16)10;
            n = n + (u8)1;
            }
        u8 i = (u8)0;
        while (i < n)
            {
            buf[cursor + i] = tmp[n - i - (u8)1];
            i = i + (u8)1;
            }
        return cursor + n;
        }

    // Signed variant: emit a leading `-` for negative inputs, then
    // hand off to _appendU16 for the magnitude.
    static u8 _appendI16(u8* buf, u8 cursor, i16 val)
        {
        if (val < (i16)0)
            {
            buf[cursor] = (u8)'-';
            cursor = cursor + (u8)1;
            val = (i16)0 - val;
            }
        return String._appendU16(buf, cursor, (u16)val);
        }

    // Build a `<Name>(v1, v2, …)` describe-style String. Every
    // auto-synthesised class description() body packs its u16-
    // widened ivar values into a heap u16[] and dispatches here,
    // so each class body stays short and the formatting logic
    // lives in one place. The working buffer is heap-allocated
    // (not a u8[N] local) to keep the function's SP frame under
    // the xt6502 budget.
    //
    // `signedMask` carries one bit per ivar (bit i set when ivar i
    // was originally signed) so an i16 -5 displays as `-5` not its
    // u16 alias `65531`. 8-bit mask caps signed-display at the
    // first 8 ivars; the rest fall through to unsigned. Synthesised
    // bodies fold each ivar's signedness into the mask at compile
    // time.
    static String* _classDescribe(u8* name, u16* vals, u8 count,
                                  u8 signedMask)
        {
        u8* buf = new u8[(u16)96];
        u8 pos = (u8)0;
        buf[pos] = (u8)'<';
        pos = pos + (u8)1;
        pos = String._appendCStr(buf, pos, name);
        buf[pos] = (u8)'>';
        pos = pos + (u8)1;
        buf[pos] = (u8)'(';
        pos = pos + (u8)1;
        for (u8 i = (u8)0; i < count; i = i + (u8)1)
            {
            if (i > (u8)0)
                {
                buf[pos] = (u8)',';
                pos = pos + (u8)1;
                buf[pos] = (u8)' ';
                pos = pos + (u8)1;
                }
            if (((signedMask >> i) & (u8)1) != (u8)0)
                {
                pos = String._appendI16(buf, pos, (i16)vals[i]);
                }
            else
                {
                pos = String._appendU16(buf, pos, vals[i]);
                }
            }
        buf[pos] = (u8)')';
        pos = pos + (u8)1;
        buf[pos] = (u8)0;
        String* s = String.withCString(buf);
        // ARC releases `buf` (raw u8* from `new u8[N]`) at scope
        // exit on heap targets — explicit `delete` here is rejected
        // by sema. The 96-byte temp is short-lived (one description
        // call before the result string is consumed and freed).
        return s;
        }
    // ── Formatting primitives (6502 build: u16 indices) ────────────────────────────────────
    // Digit emitters used by appendFormat. Kept private: callers want the
    // format string, not these.
    void _appendU32(u32 v)
        {
        if (v >= (u32)10)
            _appendU32(v / (u32)10);
        appendChar((u8)48 + (u8)(v % (u32)10));
        }

    void _appendI32(i32 v)
        {
        // '-'
        if (v < (i32)0)
            {
            appendChar((u8)45);
            _appendU32((u32)(-v));
            }
        else
            {
            _appendU32((u32)v);
            }
        }

    // Matches Stdio._emitHex: FIXED width, UPPERCASE — %x is 4 digits and %lx
    // is 8, not a minimal rendering. Deliberately the same so a format string
    // moved between Stdio.printf and appendFormat produces identical text.
    void _appendHex(u32 v, u8 digits)
        {
        u8 i = digits;
        while (i != (u8)0)
            {
            i = i - (u8)1;
            u8 nib = (u8)((v >> ((u16)i * (u16)4)) & (u32)$0F);
            appendChar(nib < (u8)10 ? nib + (u8)$30 : nib + (u8)$37); // 0-9 A-F
            }
        }

    // The same, one width up — %llx (finding #14).
    void _appendHex64(u64 v, u8 digits)
        {
        u8 i = digits;
        while (i != (u8)0)
            {
            i = i - (u8)1;
            u8 nib = (u8)((v >> ((u64)i * (u64)4)) & (u64)$0F);
            appendChar(nib < (u8)10 ? nib + (u8)$30 : nib + (u8)$37); // 0-9 A-F
            }
        }

    // Cut the string back to `n` bytes. Only used by the width-padding path,
    // which appends digits first and then inserts padding before them.
    void _truncateTo(u16 n)
        {
        if (n >= _length)
            return;
        u8* b = _bytes;
        b[n] = (u8)0;
        _length = n;
        }

    // ── Formatting ───────────────────────────────────────────────
    // `appendFormat` / `withFormat` — printf-style formatting into a String.
    //
    // This is the highest-traffic piece of the Foundation surface the compiler
    // consumes (private:docs/Design/m1-foundation-surface.md): NSMutableString's
    // appendFormat: alone is most of its 1,640 call sites, and %@ is 1,674.
    //
    // It lives here rather than in Stdio because Stdio is PER-PLATFORM (six
    // copies) and its emitters write straight to the console, so it cannot be
    // reused as a formatter. String is generic — one copy — and platform code
    // can depend on it, so Stdio can delegate here rather than the reverse.
    //
    // Width contract matches Stdio.printf and the language spec: %d/%u/%x are
    // 16-bit, %ld/%lu/%lx are 32-bit. Supported:
    //
    //     %@   Object*   — dispatches description()
    //     %s   string    — NUL-terminated bytes
    //     %d %i %u       — 16-bit signed / unsigned
    //     %ld %lu        — 32-bit signed / unsigned
    //     %x %lx         — hex, 16- and 32-bit
    //     %c             — single character
    //     %f %lf         — float (6dp) / double, via String.withFloat
    //     %e             — enum; a '?' placeholder, matching Stdio.printf
    //     %%             — a literal '%'
    //
    // Zero/space padding to a width is honoured (`%04lu`, `%3d`). This is the
    // the same specifier set Stdio.printf accepts. Integer, hex, char, string
    // and %@ renderings match it exactly — %x is 4 UPPERCASE digits and %lx is 8
    // — so those move between the two unchanged.
    //
    // ONE KNOWN DIVERGENCE: %f here renders at String.withFloat's 3 decimal
    // places, where Stdio.printf uses the host formatter at 6. Matching would
    // need a precision-taking float conversion, which String does not have yet;
    // adding `withFloat(float, u8 precision)` is the fix. Precision syntax
    // (`%.6f`) is likewise not parsed. Flagged rather than silently differing,
    // since a format string moved between the two WILL change its float output.
    void _padTo(u16 startLen, u16 width, bool zero)
        {
        u16 grew = length() - startLen;
        if (grew >= width)
            return;
        u16 pad = width - grew;
        // Digits were already appended, so insert padding before them by
        // rebuilding: cheap enough at these widths and keeps _bytes private.
        String* tail = substringFrom(startLen);
        _truncateTo(startLen);
        for (u16 i = (u16)0; i < pad; i = i + (u16)1)
            appendChar(zero ? (u8)48 : (u8)32);
        append(tail);
        }

    void appendFormat(string fmt, ...)
        {
        u8 ap;
        va_start(ap);
        u8* f = (u8*)fmt;
        u16 i = (u16)0;
        while (f[i] != (u8)0)
            {
            u8 c = f[i];
            // '%'
            if (c != (u8)37)
                {
                appendChar(c);
                i = i + (u16)1;
                continue;
                }
            i = i + (u16)1;
            if (f[i] == (u8)37)
                {
                appendChar((u8)37);
                i = i + (u16)1;
                continue;
                }

            // width / zero-pad
            bool zero = false;
            u16 width = (u16)0;
            // '0'
            if (f[i] == (u8)48)
                {
                zero = true;
                i = i + (u16)1;
                }
            while (f[i] >= (u8)48 && f[i] <= (u8)57)
                {
                width = width * (u16)10 + (u16)(f[i] - (u8)48);
                i = i + (u16)1;
                }
            bool isLong = false;
            bool isLL = false;
            // 'l'
            if (f[i] == (u8)108)
                {
                isLong = true;
                i = i + (u16)1;
                }
            // 'll'
            if (isLong && f[i] == (u8)108)
                {
                isLL = true;
                i = i + (u16)1;
                }

            u16 mark = length();
            u8 k = f[i];
            i = i + (u16)1;
            // '@'
            if (k == (u8)64)
                {
                Object* o = va_arg(ap, Object*);
                if (o == (Object*)0)
                    appendCString((u8*)"(null)");
                else
                    append(o.description());
                }
            // 's'
            else if (k == (u8)115)
                {
                appendCString((u8*)va_arg(ap, string));
                }
            // 'c'
            else if (k == (u8)99)
                {
                appendChar((u8)va_arg(ap, u16));
                }
            // 'd','i'
            else if (k == (u8)100 || k == (u8)105)
                {
                    // %lld matches Stdio.printf's 64-bit tier (finding #14: it
                    // used to fall through to "unknown" and emit LITERAL text).
                    // Gated like Array<i64>: rendering i64 pulls the 64-bit
                    // divide runtime (~3.7KB) into EVERY program that touches
                    // appendFormat, so xt6502 pays only under -DENABLE_64BIT=1.
                    // Off, the output carries a VISIBLE marker rather than the
                    // silent literal format text the finding was about.
#if ENABLE_64BIT
                if (isLL)
                    append(String.withI64(va_arg_i64(ap)));
                else if (isLong)
                    _appendI32(va_arg(ap, i32));
#else
                if (isLL)
                    {
                    va_arg_i64(ap);
                    appendCString((u8*)"<i64:ENABLE_64BIT>");
                    }
                else if (isLong)
                    _appendI32(va_arg(ap, i32));
#endif
                else
                    _appendI32((i32)va_arg(ap, i16));
                }
            // 'u'
            else if (k == (u8)117)
                {
#if ENABLE_64BIT
                if (isLL)
                    append(String.withU64(va_arg_u64(ap)));
                else if (isLong)
                    _appendU32(va_arg(ap, u32));
#else
                if (isLL)
                    {
                    va_arg_u64(ap);
                    appendCString((u8*)"<u64:ENABLE_64BIT>");
                    }
                else if (isLong)
                    _appendU32(va_arg(ap, u32));
#endif
                else
                    _appendU32((u32)va_arg(ap, u16));
                }
            // 'x'
            else if (k == (u8)120)
                {
#if ENABLE_64BIT
                if (isLL)
                    _appendHex64(va_arg_u64(ap), (u8)16);
                else if (isLong)
                    _appendHex(va_arg(ap, u32), (u8)8);
#else
                if (isLL)
                    {
                    va_arg_u64(ap);
                    appendCString((u8*)"<u64:ENABLE_64BIT>");
                    }
                else if (isLong)
                    _appendHex(va_arg(ap, u32), (u8)8);
#endif
                else
                    _appendHex((u32)va_arg(ap, u16), (u8)4);
                }
            // 'f'
            else if (k == (u8)102)
                {
                // %f float / %lf double, via the existing String.withFloat.
                if (isLong)
                    append(String.withFloat((float)va_arg(ap, double)));
                else
                    append(String.withFloat(va_arg(ap, float)));
                }
            // 'e'
            else if (k == (u8)101)
                {
                // Enum: Stdio.printf emits the underlying value; match that.
                if (isLong)
                    _appendU32(va_arg(ap, u32));
                else
                    _appendU32((u32)va_arg(ap, u16));
                }
            else
                {
                // Unknown specifier: emit it literally rather than silently
                // dropping the argument's worth of output.
                appendChar((u8)37);
                appendChar(k);
                }
            if (width > (u16)0)
                _padTo(mark, width, zero);
            }
        va_end(ap);
        }

    // The same formatting as a CONSTRUCTOR:
    //     return String.withFormat("(%ld|%ld)", x, y);
    // instead of building a string and appending to it in four statements.
    //
    // It FORWARDS its tail to appendFormat rather than repeating the parse
    // loop. That loop used to be duplicated here — 60 lines, in two support
    // trees, four copies to keep in step by hand — because a variadic had no
    // way to hand its arguments to another one. `...` in the argument position
    // is that way now (private:docs/bugs/047), and this is what it was built for.
    static String* withFormat(string fmt, ...)
        {
        String* r = String.withCString((u8*)"");
        r.appendFormat(fmt, ...);
        return r;
        }

    // ── 0.4 byte-name aliases ────────────────────────────────────
    // 0.4 renamed String's byte-oriented methods (byteAt, byteIndexOf, …) so
    // the char-oriented UTF-8 layer on the HOSTED targets could take the
    // plain names (private:docs/Design/string-utf8.md). This target keeps its byte
    // world and its old names — nothing here is deprecated — but shared
    // sources (fixtures, the self-hosted compiler) are written against the
    // new spellings, so each gets a thin alias. No char layer exists here.
    since("0.4") u8 byteAt(u16 idx)
        {
        return charAt(idx);
        }
    since("0.4") void appendByte(u8 ch)
        {
        appendChar(ch);
        }
    since("0.4") void insertByte(u16 at, u8 ch)
        {
        insertChar(at, ch);
        }
    since("0.4") void insertAtByte(u16 at, String* other)
        {
        insert(at, other);
        }
    since("0.4") void insertCStringAtByte(u16 at, u8* src)
        {
        insertCString(at, src);
        }
    since("0.4") void deleteByteRange(u16 at, u16 len)
        {
        deleteRange(at, len);
        }
    since("0.4") void replaceByteRange(u16 at, u16 len, String* other)
        {
        replaceRange(at, len, other);
        }
    since("0.4") u16 indexOfByte(u8 ch)
        {
        return indexOfChar(ch);
        }
    since("0.4") u16 lastIndexOfByte(u8 ch)
        {
        return lastIndexOfChar(ch);
        }
    since("0.4") u16 byteIndexOf(String* needle)
        {
        return indexOf(needle);
        }
    since("0.4") u16 byteIndexOf(String* needle, u16 from)
        {
        return indexOf(needle, from);
        }
    since("0.4") String* substringFromByte(u16 from)
        {
        return substringFrom(from);
        }
    since("0.4") String* substringBytes(u16 from, u16 len)
        {
        return substring(from, len);
        }
    since("0.4") String* substringToByte(u16 to)
        {
        return substringTo(to);
        }
    since("0.4") u16 byteIndexOfSet(CharacterSet* set)
        {
        return indexOfCharacterFrom(set);
        }
    since("0.4") u16 lastByteIndexOfSet(CharacterSet* set)
        {
        return lastIndexOfCharacterFrom(set);
        }
    since("0.4") bool containsByteFromSet(CharacterSet* set)
        {
        return containsCharacterFrom(set);
        }
    since("0.4") Array* splitOnSet(CharacterSet* set)
        {
        return split(set);
        }
    since("0.4") Array* splitOnByte(u8 sep)
        {
        return split(sep);
        }
    }
