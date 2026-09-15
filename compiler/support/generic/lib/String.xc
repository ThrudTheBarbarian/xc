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
// heap-owned u8* with a trailing `\0`, exposing length / byteAt /
// equals helpers. A bare `string` (alias for `u8*`) covers the
// passing-strings-around use case in xtc today; this class adds the
// "stored as a class-instance value alongside other primitives"
// shape that container types will eventually need.
//
// Usage:
//   String* s = String.withCString("hello");
//   for (u32 i = (u32)0; i < s.byteLength(); i++)
//       Stdio.printf("%c", s.byteAt(i));
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

#import "Comparable.xc"
#import "CharacterSet.xc"
#import "Copying.xc"
#import "Hashable.xc"
#import "Array.xc"

// Free a String's byte buffer. `new u8[N]` comes from the same allocator as any
// object — a heap header with refcount 1 and no destructor — so releasing it to
// zero reclaims it. Null-safe.
//
// The 6502 build of this file uses a raw `_heap_free` instead: a raw buffer
// there carries no destructor descriptor, and the ARC release path dispatches
// one. See support/xt6502/lib/String.xc.
void _string_bytes_free(u8* buf)
    {
    __arc_release((pointer)buf);
    }

// The encodings String can transcode AT ITS EDGE — internally a String is
// always UTF-8 (private:docs/Design/string-utf8.md §4). Constructors decode, the
// exporter encodes; there is no per-String encoding mode.
enum StrEncoding = {ENC_UTF8 = 0, ENC_ASCII = 1, ENC_LATIN1 = 2,
    ENC_UTF16LE = 3, ENC_UTF16BE = 4};

class String<Comparable, Hashable, Copying>
    {
    u8* _bytes;    // owned heap allocation, includes trailing \0
    u32 _length;   // cached length (number of bytes before the \0)
    u32 _capacity; // bytes usable in _bytes EXCLUDING the trailing \0

    void init(void)
        {
        _bytes = (u8*)0;
        _length = (u32)0;
        _capacity = (u32)0;
        }

    // Build from a null-terminated source pointer (string literal,
    // existing buffer, etc). Bytes are copied into a fresh heap
    // allocation so the String owns its own storage.
    static String* withCString(u8* src)
        {
        String* s = new String();
        u32 len = String._cstringLen(src);
        u8* buf = new u8[len + (u32)1];
        for (u32 i = (u32)0; i <= len; i++)
            {
            buf[i] = src[i];
            }
        s._bytes = buf;
        s._length = len;
        s._capacity = len;
        return s;
        }

    // Length scanner — walks the source until the first \0 or 64 KB,
    // whichever comes first. The cap is the natural u32 limit;
    // an unterminated source past that point is a programming error
    // and the scanner returns $FFFF_FFFF (max u32) as a clue.
    static u32 _cstringLen(u8* src)
        {
        u32 i = (u32)0;
        while (src[i] != (u8)0)
            {
            i = i + (u32)1;
            if (i == (u32)0)
                return $FFFF_FFFF; // wrapped — unterminated
            }
        return i;
        }

    // ── Accessors ────────────────────────────────────────────────
    // Subscript reads route through a local copy of the heap pointer rather
    // than subscripting the ivar directly — the shape the banked-heap codegen
    // wants.
    u32 byteLength(void)
        {
        return _length;
        }
    since("0.4") u8 byteAt(u32 idx)
        {
        u8* b = _bytes;
        return b[idx];
        }
    // BORROW: a pointer into the String's own buffer, valid until the String
    // is next GROWN — append/appendByte/appendCString/appendFormat/insert may
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
        u8* out = new u8[_length + (u32)1];
        u8* b = _bytes;
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
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
    static String* withBytes(u8* src, u32 n)
        {
        String* s = new String();
        u8* buf = new u8[n + (u32)1];
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            buf[i] = src[i];
        buf[n] = (u8)0;
        s._bytes = buf;
        s._length = n;
        s._capacity = n;
        return s;
        }

    bool isEmpty(void)
        {
        return _length == (u32)0;
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
            s.appendByte((u8)'0');
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
            s.appendByte(tmp[n]);
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
    // Also what `appendFormat`'s %lld/%llu render through (finding #14 —
    // appendFormat used to stop at a single `l`, matching an older Stdio;
    // Stdio.printf grew the 64-bit tier and this formatter had drifted, so
    // `%lld` fell through to "unknown specifier" and emitted LITERAL text).
    static String* withU64(u64 v)
        {
        String* s = String.withCString("");
        if (v == (u64)0)
            {
            s.appendByte((u8)'0');
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
            s.appendByte(tmp[n]);
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
            s.appendByte((u8)'-');
        s.append(String.withI32((i32)ip));
        s.appendByte((u8)'.');
        // leading zeros inside the fraction
        i32 probe = (i32)scale / (i32)10;
        while (probe > (i32)1 && fp < probe)
            {
            s.appendByte((u8)'0');
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
    // Capacity GROWS GEOMETRICALLY — 16, then doubling — and a request that
    // already fits returns without touching the heap. This used to allocate,
    // copy and free on EVERY appended byte, which made appendByte O(n) and
    // building an n-byte string O(n²): the asm emitters self-hosting depends on
    // append a character at a time, so that quadratic was the whole cost model.
    //
    // `_capacity` counts usable bytes NOT counting the trailing NUL, so the
    // allocation is always capacity+1 and `_bytes[_length]` is always writable.
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

        u8* fresh = new u8[cap + (u32)1];
        u8* old = _bytes;
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
            fresh[i] = old[i];
        fresh[_length] = (u8)0;
        _bytes = fresh;
        _capacity = cap;
        _string_bytes_free(old);
        }

    // Bytes allocated, not bytes used. Exposed for tests and for a caller that
    // wants to pre-size before a long run of appends.
    u32 capacity(void)
        {
        return _capacity;
        }

    void reserve(u32 need)
        {
        _reserve(need);
        }

    // ── Mutation ─────────────────────────────────────────────────
    // `append` mutates the receiver; `appending` returns a new String and
    // leaves the receiver alone. Same pair as Foundation's
    // appendString: / stringByAppendingString:.
    void append(String* other)
        {
        if (other == 0 || other.byteLength() == (u32)0)
            return;
        u32 n = other.byteLength();
        _reserve(_length + n);
        u8* dst = _bytes;
        u8* src = other.cString();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            dst[_length + i] = src[i];
        _length = _length + n;
        dst[_length] = (u8)0;
        }

    void appendCString(u8* src)
        {
        append(String.withCString(src));
        }

    since("0.4") void appendByte(u8 ch)
        {
        _reserve(_length + (u32)1);
        u8* dst = _bytes;
        dst[_length] = ch;
        _length = _length + (u32)1;
        dst[_length] = (u8)0;
        }

    // `n` bytes from a raw pointer — no NUL needed, and the bytes may be
    // anything including zero. The counterpart of String.withBytes, and what
    // lets the search/replace paths copy a slice without allocating a temporary
    // String for it.
    //
    // `src` must NOT point into this String's own buffer: appending may
    // reallocate and free it. Splice a String into itself with insert /
    // replaceByteRange, which handle that case.
    void appendBytes(u8* src, u32 n)
        {
        if (n == (u32)0)
            return;
        _reserve(_length + n);
        u8* dst = _bytes;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
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
    // buffer or copies first (see `insert` / `replaceByteRange`).
    void _splice(u32 at, u32 remove, u8* src, u32 srcLen)
        {
        if (at > _length)
            at = _length;
        u32 avail = _length - at;
        if (remove > avail)
            remove = avail;

        u32 newLen = _length - remove + srcLen;
        _reserve(newLen);
        u8* b = _bytes;

        if (srcLen > remove)
            {
            // Growing: shift the tail right, walking backwards so the
            // overlapping copy doesn't overwrite what it has yet to read.
            u32 delta = srcLen - remove;
            u32 i = _length;
            while (i > at + remove)
                {
                b[i - (u32)1 + delta] = b[i - (u32)1];
                i = i - (u32)1;
                }
            }
        else if (srcLen < remove)
            {
            // Shrinking: shift the tail left, forwards.
            u32 delta = remove - srcLen;
            for (u32 i = at + remove; i < _length; i = i + (u32)1)
                b[i - delta] = b[i];
            }

        for (u32 i = (u32)0; i < srcLen; i = i + (u32)1)
            b[at + i] = src[i];
        _length = newLen;
        b[newLen] = (u8)0;
        }

    // Insert `other` before index `at`. `at == byteLength()` is `append`.
    since("0.4") void insertAtByte(u32 at, String* other)
        {
        if (other == 0 || other.byteLength() == (u32)0)
            return;
        // Inserting a String into ITSELF would read from a buffer the splice
        // may already have freed — take a copy of the source first.
        if (other == self)
            {
            String* dup = String.withString(self);
            _splice(at, (u32)0, dup.cString(), dup.byteLength());
            return;
            }
        _splice(at, (u32)0, other.cString(), other.byteLength());
        }

    since("0.4") void insertCStringAtByte(u32 at, u8* src)
        {
        _splice(at, (u32)0, src, String._cstringLen(src));
        }

    since("0.4") void insertByte(u32 at, u8 ch)
        {
        u8 one[1];
        one[0] = ch;
        _splice(at, (u32)0, &one[0], (u32)1);
        }

    // Remove `len` bytes at `at` — Foundation's deleteCharactersInRange:.
    since("0.4") void deleteByteRange(u32 at, u32 len)
        {
        _splice(at, len, (u8*)0, (u32)0);
        }

    // Replace `len` bytes at `at` with `other` — replaceCharactersInRange:.
    since("0.4") void replaceByteRange(u32 at, u32 len, String* other)
        {
        if (other == 0)
            {
            deleteByteRange(at, len);
            return;
            }
        if (other == self)
            {
            String* dup = String.withString(self);
            _splice(at, len, dup.cString(), dup.byteLength());
            return;
            }
        _splice(at, len, other.cString(), other.byteLength());
        }

    // Discard the contents, KEEP the buffer. A String reused as a scratch
    // accumulator — the emitter idiom — then costs one allocation, not one per
    // round.
    void clear(void)
        {
        _length = (u32)0;
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
    u32 replaceOccurrences(String* find, String* sub)
        {
        if (find == 0)
            return (u32)0;
        u32 flen = find.byteLength();
        if (flen == (u32)0 || flen > _length)
            return (u32)0;

        // A substitution string that IS this String would dangle across the
        // first splice; and a needle that is this String stops matching the
        // moment the first splice edits it. Copy both.
        String* needle = (find == self) ? String.withString(self) : find;
        String* repl = (sub == self) ? String.withString(self) : sub;
        u32 slen = (repl == 0) ? (u32)0 : repl.byteLength();

        u32 n = (u32)0;
        u32 i = (u32)0;
        while (i + flen <= _length)
            {
            if (_matchesAt(i, needle))
                {
                _splice(i, flen, (slen == (u32)0) ? (u8*)0 : repl.cString(), slen);
                i = i + slen;
                n = n + (u32)1;
                }
            else
                {
                i = i + (u32)1;
                }
            }
        return n;
        }

    // ── Search ───────────────────────────────────────────────────
    // Byte index of the first occurrence, or String.notFound().
    static u32 notFound(void)
        {
        return $FFFFFFFF;
        }

    since("0.4") u32 indexOfByte(u8 ch)
        {
        u8* b = _bytes;
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
            {
            if (b[i] == ch)
                return i;
            }
        return String.notFound();
        }

    since("0.4") u32 lastIndexOfByte(u8 ch)
        {
        u8* b = _bytes;
        u32 i = _length;
        while (i > (u32)0)
            {
            i = i - (u32)1;
            if (b[i] == ch)
                return i;
            }
        return String.notFound();
        }

    // Does `needle` sit at exactly `at`? The primitive under both the search
    // and the in-place replace, neither of which should allocate to ask.
    bool _matchesAt(u32 at, String* needle)
        {
        if (needle == 0)
            return false;
        u32 n = needle.byteLength();
        if (at + n > _length)
            return false;
        u8* h = _bytes;
        u8* p = needle.cString();
        for (u32 j = (u32)0; j < n; j = j + (u32)1)
            {
            if (h[at + j] != p[j])
                return false;
            }
        return true;
        }

    // Naive substringBytes search. Fine for the string lengths a UI deals in; if a
    // hot path ever needs better, this is the one place to change.
    since("0.4") u32 byteIndexOf(String* needle)
        {
        return byteIndexOf(needle, (u32)0);
        }

    // The same search starting at `from` — what a scanning loop wants, and
    // what stops `replacing` allocating a fresh substringBytes per iteration just to
    // ask "where is the next one".
    since("0.4") u32 byteIndexOf(String* needle, u32 from)
        {
        if (needle == 0)
            return String.notFound();
        u32 n = needle.byteLength();
        if (from > _length)
            return String.notFound();
        if (n == (u32)0)
            return from; // empty needle matches at `from`
        if (from + n > _length)
            return String.notFound();

        u32 last = _length - n;
        for (u32 i = from; i <= last; i = i + (u32)1)
            {
            if (_matchesAt(i, needle))
                return i;
            }
        return String.notFound();
        }

    bool contains(String* needle)
        {
        return byteIndexOf(needle) != String.notFound();
        }

    bool hasPrefix(String* p)
        {
        if (p == 0)
            return false;
        u32 n = p.byteLength();
        if (n > _length)
            return false;
        u8* a = _bytes;
        u8* b = p.cString();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
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
        u32 n = s.byteLength();
        if (n > _length)
            return false;
        u8* a = _bytes;
        u8* b = s.cString();
        u32 off = _length - n;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
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
    since("0.4") String* substringFromByte(u32 from)
        {
        if (from >= _length)
            return String.withCString("");
        return String.withBytes(_bytesAt(from), _length - from);
        }

    since("0.4") String* substringBytes(u32 from, u32 len)
        {
        if (from >= _length)
            return String.withCString("");
        u32 avail = _length - from;
        u32 n = (len < avail) ? len : avail;
        return String.withBytes(_bytesAt(from), n);
        }

    since("0.4") String* substringToByte(u32 to)
        {
        return substringBytes((u32)0, to);
        }

    u8* _bytesAt(u32 off)
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
    u32 getBytes(u8* dst, u32 max)
        {
        if (dst == (u8*)0)
            return (u32)0;
        u32 n = (max < _length) ? max : _length;
        u8* b = _bytes;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            dst[i] = b[i];
        return n;
        }

    // The same as byteLength(): this class stores bytes, and an xtc `string` is
    // UTF-8 by convention, so a byte count and a length are the same number.
    // Present under its own name because a call site asking about BYTES is
    // making a different assumption than one asking about characters, and one
    // of them will matter the day a non-ASCII encoding shows up.

    // ── Case ─────────────────────────────────────────────────────
    // ASCII only, which is what the whole class assumes.
    String* uppercased(void)
        {
        String* out = String.withString(self);
        u8* b = out.cString();
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
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
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
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
        u32 lo = (u32)0;
        while (lo < _length && String._isSpace(b[lo]))
            lo = lo + (u32)1;
        u32 hi = _length;
        while (hi > lo && String._isSpace(b[hi - (u32)1]))
            hi = hi - (u32)1;
        return substringBytes(lo, hi - lo);
        }

    // ── Character-set search ─────────────────────────────────────
    // rangeOfCharacterFromSet: / componentsSeparatedByCharactersInSet: /
    // stringByTrimmingCharactersInSet: — the methods M1 said needed "a
    // character-set notion xtc lacks entirely". CharacterSet.xc is that notion:
    // a 256-bit bitmap, so each test below is a shift and an AND.
    //
    // A null set matches nothing, which makes every method here degrade to the
    // no-op answer rather than to a fault.
    since("0.4") u32 byteIndexOfSet(CharacterSet* set)
        {
        if (set == 0)
            return String.notFound();
        u8* b = _bytes;
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
            {
            if (set.contains(b[i]))
                return i;
            }
        return String.notFound();
        }

    since("0.4") u32 lastByteIndexOfSet(CharacterSet* set)
        {
        if (set == 0)
            return String.notFound();
        u8* b = _bytes;
        u32 i = _length;
        while (i > (u32)0)
            {
            i = i - (u32)1;
            if (set.contains(b[i]))
                return i;
            }
        return String.notFound();
        }

    since("0.4") bool containsByteFromSet(CharacterSet* set)
        {
        return byteIndexOfSet(set) != String.notFound();
        }

    // Trim any leading and trailing bytes in `set`. The no-argument `trimmed()`
    // is the same operation over whitespace-and-newlines, kept as its own
    // implementation because it is the common case and needs no set built.
    String* trimmed(CharacterSet* set)
        {
        if (set == 0)
            return String.withString(self);
        u8* b = _bytes;
        u32 lo = (u32)0;
        while (lo < _length && set.contains(b[lo]))
            lo = lo + (u32)1;
        u32 hi = _length;
        while (hi > lo && set.contains(b[hi - (u32)1]))
            hi = hi - (u32)1;
        return substringBytes(lo, hi - lo);
        }

    // Split on ANY byte in the set — componentsSeparatedByCharactersInSet:.
    // Consecutive separators still yield empty components, exactly as the
    // single-byte `split` does, because a CSV depends on it.
    since("0.4") Array* splitOnSet(CharacterSet* set)
        {
        Array* parts = new Array();
        if (set == 0)
            {
            parts.add(String.withString(self));
            return parts;
            }
        u8* b = _bytes;
        u32 start = (u32)0;
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
            {
            if (set.contains(b[i]))
                {
                parts.add(substringBytes(start, i - start));
                start = i + (u32)1;
                }
            }
        parts.add(substringBytes(start, _length - start));
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
    since("0.4") Array* splitOnByte(u8 sep)
        {
        Array* parts = new Array();
        u8* b = _bytes;
        u32 start = (u32)0;
        for (u32 i = (u32)0; i < _length; i = i + (u32)1)
            {
            if (b[i] == sep)
                {
                parts.add(substringBytes(start, i - start));
                start = i + (u32)1;
                }
            }
        parts.add(substringBytes(start, _length - start));
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
        for (u32 i = (u32)0; i < parts.count(); i = i + (u32)1)
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
    // Scans with the offset form of byteIndexOf and copies slices with appendBytes.
    // The first version built a fresh substringFromByte(i) — a whole copy of the
    // remaining text — on every iteration, so replacing k needles in an n-byte
    // string allocated O(k) strings totalling O(k·n) bytes.
    String* replacing(String* find, String* sub)
        {
        if (find == 0 || find.byteLength() == (u32)0)
            return String.withString(self);

        String* out = String.withCString("");
        u32 n = find.byteLength();
        u32 i = (u32)0;
        while (i < _length)
            {
            u32 at = byteIndexOf(find, i);
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
    u32 _lastComponentEnd(void)
        {
        u8* b = _bytes;
        u32 end = _length;
        while (end > (u32)0 && b[end - (u32)1] == String.pathSeparator())
            end = end - (u32)1;
        return end;
        }

    // Index of the first byte of the component ending at `end`.
    u32 _lastComponentStart(u32 end)
        {
        u8* b = _bytes;
        u32 start = end;
        while (start > (u32)0 && b[start - (u32)1] != String.pathSeparator())
            start = start - (u32)1;
        return start;
        }

    bool isAbsolutePath(void)
        {
        if (_length == (u32)0)
            return false;
        u8* b = _bytes;
        return b[0] == String.pathSeparator();
        }

    String* lastPathComponent(void)
        {
        u32 end = _lastComponentEnd();
        // Nothing but separators: the root is its own last component.
        if (end == (u32)0)
            return (_length == (u32)0) ? String.withCString("") : String.withCString("/");
        u32 start = _lastComponentStart(end);
        return substringBytes(start, end - start);
        }

    String* deletingLastPathComponent(void)
        {
        u32 end = _lastComponentEnd();
        if (end == (u32)0)
            return (_length == (u32)0) ? String.withCString("") : String.withCString("/");

        u32 start = _lastComponentStart(end);
        // Separators BETWEEN the parent and this component belong to neither.
        u8* b = _bytes;
        u32 cut = start;
        while (cut > (u32)0 && b[cut - (u32)1] == String.pathSeparator())
            cut = cut - (u32)1;

        if (cut == (u32)0)
            {
            // "/usr" → "/" (absolute), "usr" → "" (relative).
            return (start > (u32)0) ? String.withCString("/") : String.withCString("");
            }
        return substringBytes((u32)0, cut);
        }

    // Index of the '.' introducing the last component's extension, or
    // notFound(). A dot that STARTS the component (".bashrc") or ENDS it
    // ("archive.") introduces nothing.
    u32 _extensionDot(void)
        {
        u32 end = _lastComponentEnd();
        if (end == (u32)0)
            return String.notFound();
        u32 start = _lastComponentStart(end);
        u8* b = _bytes;
        u32 i = end;
        while (i > start)
            {
            i = i - (u32)1;
            if (b[i] == (u8)'.')
                {
                if (i == start)
                    return String.notFound(); // ".bashrc"
                if (i + (u32)1 >= end)
                    return String.notFound(); // "archive."
                return i;
                }
            }
        return String.notFound();
        }

    String* pathExtension(void)
        {
        u32 dot = _extensionDot();
        if (dot == String.notFound())
            return String.withCString("");
        u32 end = _lastComponentEnd();
        return substringBytes(dot + (u32)1, end - dot - (u32)1);
        }

    String* deletingPathExtension(void)
        {
        u32 dot = _extensionDot();
        if (dot == String.notFound())
            return String.withString(self);
        return substringBytes((u32)0, dot);
        }

    // "a" + "b" → "a/b", with exactly one separator however many either side
    // brings. An empty receiver yields the component alone, so a loop can start
    // from "" and keep joining.
    String* appendingPathComponent(String* component)
        {
        u32 end = _lastComponentEnd(); // receiver, trailing '/' gone
        String* base = substringBytes((u32)0, end);

        u32 skip = (u32)0;
        if (component != 0)
            {
            while (skip < component.byteLength() && component.byteAt(skip) == String.pathSeparator())
                skip = skip + (u32)1;
            }
        String* tail = (component == 0) ? String.withCString("")
                                        : component.substringFromByte(skip);
        // Its own trailing separators go too, so the result never ends in one.
        while (tail.byteLength() > (u32)0 && tail.byteAt(tail.byteLength() - (u32)1) == String.pathSeparator())
            tail.deleteByteRange(tail.byteLength() - (u32)1, (u32)1);

        if (tail.isEmpty())
            {
            if (!base.isEmpty())
                return base;
            return (_length == (u32)0) ? String.withCString("")
                                       : String.withCString("/");
            }
        if (base.isEmpty())
            {
            // The receiver was empty (relative) or all separators (root).
            if (_length == (u32)0)
                return tail;
            String* abs = String.withCString("/");
            abs.append(tail);
            return abs;
            }
        base.appendByte(String.pathSeparator());
        base.append(tail);
        return base;
        }

    // "file" + "txt" → "file.txt". An empty extension is a copy, not a
    // trailing dot.
    String* appendingPathExtension(String* ext)
        {
        u32 end = _lastComponentEnd();
        String* out = substringBytes((u32)0, end);
        if (ext == 0 || ext.isEmpty())
            return out;
        out.appendByte((u8)'.');
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

    // <Copying>: an independent String with the same bytes. Shallow is the
    // same as deep here — a String owns only its byte buffer.
    String* copy(void)
        {
        return String.withString(self);
        }

    // ── Formatting primitives ────────────────────────────────────
    // Digit emitters used by appendFormat. Kept private: callers want the
    // format string, not these.
    void _appendU32(u32 v)
        {
        if (v >= (u32)10)
            _appendU32(v / (u32)10);
        appendByte((u8)48 + (u8)(v % (u32)10));
        }

    void _appendI32(i32 v)
        {
        // '-'
        if (v < (i32)0)
            {
            appendByte((u8)45);
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
            u8 nib = (u8)((v >> ((u32)i * (u32)4)) & (u32)$0F);
            appendByte(nib < (u8)10 ? nib + (u8)$30 : nib + (u8)$37); // 0-9 A-F
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
            appendByte(nib < (u8)10 ? nib + (u8)$30 : nib + (u8)$37); // 0-9 A-F
            }
        }

    // Cut the string back to `n` bytes. Only used by the width-padding path,
    // which appends digits first and then inserts padding before them.
    void _truncateTo(u32 n)
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
    void _padTo(u32 startLen, u32 width, bool zero)
        {
        u32 grew = byteLength() - startLen;
        if (grew >= width)
            return;
        u32 pad = width - grew;
        // Digits were already appended, so insert padding before them by
        // rebuilding: cheap enough at these widths and keeps _bytes private.
        String* tail = substringFromByte(startLen);
        _truncateTo(startLen);
        for (u32 i = (u32)0; i < pad; i = i + (u32)1)
            appendByte(zero ? (u8)48 : (u8)32);
        append(tail);
        }

    void appendFormat(string fmt, ...)
        {
        u8 ap;
        va_start(ap);
        u8* f = (u8*)fmt;
        u32 i = (u32)0;
        while (f[i] != (u8)0)
            {
            u8 c = f[i];
            // '%'
            if (c != (u8)37)
                {
                appendByte(c);
                i = i + (u32)1;
                continue;
                }
            i = i + (u32)1;
            if (f[i] == (u8)37)
                {
                appendByte((u8)37);
                i = i + (u32)1;
                continue;
                }

            // width / zero-pad
            bool zero = false;
            u32 width = (u32)0;
            // '0'
            if (f[i] == (u8)48)
                {
                zero = true;
                i = i + (u32)1;
                }
            while (f[i] >= (u8)48 && f[i] <= (u8)57)
                {
                width = width * (u32)10 + (u32)(f[i] - (u8)48);
                i = i + (u32)1;
                }
            bool isLong = false;
            bool isLL = false;
            // 'l'
            if (f[i] == (u8)108)
                {
                isLong = true;
                i = i + (u32)1;
                }
            // 'll'
            if (isLong && f[i] == (u8)108)
                {
                isLL = true;
                i = i + (u32)1;
                }

            u32 mark = byteLength();
            u8 k = f[i];
            i = i + (u32)1;
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
                appendByte((u8)va_arg(ap, u16));
                }
            // 'd','i'
            else if (k == (u8)100 || k == (u8)105)
                {
                // %lld matches Stdio.printf's 64-bit tier (finding #14: the
                // specifier used to fall through to "unknown" and the output
                // was the LITERAL text "%ld" — a heartbeat file that existed,
                // had a fresh mtime, and contained nothing parseable).
                if (isLL)
                    append(String.withI64(va_arg_i64(ap)));
                else if (isLong)
                    _appendI32(va_arg(ap, i32));
                else
                    _appendI32((i32)va_arg(ap, i16));
                }
            // 'u'
            else if (k == (u8)117)
                {
                if (isLL)
                    append(String.withU64(va_arg_u64(ap)));
                else if (isLong)
                    _appendU32(va_arg(ap, u32));
                else
                    _appendU32((u32)va_arg(ap, u16));
                }
            // 'x'
            else if (k == (u8)120)
                {
                if (isLL)
                    _appendHex64(va_arg_u64(ap), (u8)16);
                else if (isLong)
                    _appendHex(va_arg(ap, u32), (u8)8);
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
                appendByte((u8)37);
                appendByte(k);
                }
            if (width > (u32)0)
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

    // ── UTF-8: the code-point layer ──────────────────────────────
    // The String's bytes ARE UTF-8; everything above this line is
    // byte-oriented and stays that way (byte order is code-point order, so
    // equals/compare/hash were already right). "Char" in a name below always
    // means CODE POINT. Design + the decisions behind it:
    // private:docs/Design/string-utf8.md.
    //
    // ONE strict validator, which everything else routes through.
    // _decodeLenAt answers "how many bytes does a WELL-FORMED sequence
    // starting at byte `at` occupy?" — 1..4, or 0 when the bytes there are
    // malformed in any of the ways UTF-8 can be: a C0/C1/F5+ lead, a bare
    // continuation, a truncated tail, an overlong form, a surrogate
    // (U+D800..DFFF), anything above U+10FFFF. Value ASSEMBLY (charAtByte)
    // trusts a non-zero answer and just shifts bits — the validity logic
    // lives here and nowhere else, because two decoders that mostly agree is
    // how "compliant" quietly stops being true.
    u32 _decodeLenAt(u32 at)
        {
        u8* b = _bytes;
        u32 n = _length;
        if (at >= n)
            {
            return (u32)0;
            }
        u32 c0 = (u32)b[at];
        // ASCII
        if (c0 < (u32)0x80)
            {
            return (u32)1;
            }
        u32 need = (u32)0;
        u32 cp = (u32)0;
        u32 min = (u32)0;
        // 2 bytes
        if (c0 >= (u32)0xC2 && c0 <= (u32)0xDF)
            {
            need = (u32)1;
            cp = c0 & (u32)0x1F;
            min = (u32)0x80;
            }
        // 3 bytes
        if (c0 >= (u32)0xE0 && c0 <= (u32)0xEF)
            {
            need = (u32)2;
            cp = c0 & (u32)0x0F;
            min = (u32)0x800;
            }
        // 4 bytes
        if (c0 >= (u32)0xF0 && c0 <= (u32)0xF4)
            {
            need = (u32)3;
            cp = c0 & (u32)0x07;
            min = (u32)0x10000;
            }
        // bad lead byte
        if (need == (u32)0)
            {
            return (u32)0;
            }
        // truncated
        if (at + need >= n)
            {
            return (u32)0;
            }
        u32 k = (u32)1;
        while (k <= need)
            {
            u32 cc = (u32)b[at + k];
            if ((cc & (u32)0xC0) != (u32)0x80)
                {
                return (u32)0;
                }
            cp = (cp << (u32)6) | (cc & (u32)0x3F);
            k = k + (u32)1;
            }
        // overlong
        if (cp < min)
            {
            return (u32)0;
            }
        if (cp >= (u32)0xD800 && cp <= (u32)0xDFFF)
            {
            return (u32)0;
            }
        if (cp > (u32)0x10FFFF)
            {
            return (u32)0;
            }
        return need + (u32)1;
        }

    // True at 0, at byteLength(), and at any byte that does not continue an
    // earlier sequence. (Boundary of a WELL-FORMED string; on mangled bytes
    // it still answers, treating each invalid byte as its own character.)
    since("0.4") bool isCharBoundary(u32 at)
        {
        if (at >= _length)
            {
            return true;
            }
        u8* b = _bytes;
        return ((u32)b[at] & (u32)0xC0) != (u32)0x80;
        }

    // Code points in the string: counts the non-continuation bytes, so a
    // malformed byte counts as one character — consistent with charByteLength's
    // consume-1 rule. O(n); nothing is cached.
    since("0.4") u32 charCount(void)
        {
        u8* b = _bytes;
        u32 n = _length;
        u32 count = (u32)0;
        u32 i = (u32)0;
        while (i < n)
            {
            if (((u32)b[i] & (u32)0xC0) != (u32)0x80)
                {
                count = count + (u32)1;
                }
            i = i + (u32)1;
            }
        return count;
        }

    // The code point whose sequence starts at byte `at` (U+FFFD if malformed
    // or past the end).
    since("0.4") u32 charAtByte(u32 at)
        {
        u32 len = _decodeLenAt(at);
        if (len == (u32)0)
            {
            return (u32)0xFFFD;
            }
        u8* b = _bytes;
        u32 c0 = (u32)b[at];
        if (len == (u32)1)
            {
            return c0;
            }
        u32 cp = c0 & ((u32)0x7F >> len); // 0x1F / 0x0F / 0x07
        u32 k = (u32)1;
        while (k < len)
            {
            cp = (cp << (u32)6) | ((u32)b[at + k] & (u32)0x3F);
            k = k + (u32)1;
            }
        return cp;
        }

    // Byte length (1..4) of the well-formed sequence at `at`; 1 when
    // malformed, so `at + charByteLength(at)` always advances.
    since("0.4") u32 charByteLength(u32 at)
        {
        u32 len = _decodeLenAt(at);
        // malformed: consume 1, always advance
        if (len == (u32)0)
            {
            return (u32)1;
            }
        return len;
        }

    // Byte index of the next character boundary after `at`; byteLength() once
    // past the last character.
    since("0.4") u32 nextCharByte(u32 at)
        {
        if (at >= _length)
            {
            return _length;
            }
        u32 i = at + charByteLength(at);
        if (i > _length)
            {
            return _length;
            }
        return i;
        }

    // Byte index of the boundary at or before `at - 1`; 0 from the first
    // character (or from 0 itself).
    since("0.4") u32 prevCharByte(u32 at)
        {
        if (at == (u32)0)
            {
            return (u32)0;
            }
        u32 i = at - (u32)1;
        while (i > (u32)0 && !isCharBoundary(i))
            {
            i = i - (u32)1;
            }
        return i;
        }

    // Byte index of the n-th code point (0-based); byteLength() when the string
    // has fewer than n+1 characters.
    since("0.4") u32 byteIndexOfChar(u32 n)
        {
        u32 i = (u32)0;
        u32 seen = (u32)0;
        while (i < _length && seen < n)
            {
            i = nextCharByte(i);
            seen = seen + (u32)1;
            }
        return i;
        }

    // Encode one code point and append it. A surrogate or a value above
    // U+10FFFF appends U+FFFD instead — the same repair the decoder makes,
    // so the class never MANUFACTURES invalid UTF-8 whatever it is fed.
    since("0.4") void appendChar(u32 cp)
        {
        if (cp >= (u32)0xD800 && cp <= (u32)0xDFFF)
            {
            cp = (u32)0xFFFD;
            }
        if (cp > (u32)0x10FFFF)
            {
            cp = (u32)0xFFFD;
            }
        if (cp < (u32)0x80)
            {
            appendByte((u8)cp);
            return;
            }
        if (cp < (u32)0x800)
            {
            appendByte((u8)((u32)0xC0 | (cp >> (u32)6)));
            appendByte((u8)((u32)0x80 | (cp & (u32)0x3F)));
            return;
            }
        if (cp < (u32)0x10000)
            {
            appendByte((u8)((u32)0xE0 | (cp >> (u32)12)));
            appendByte((u8)((u32)0x80 | ((cp >> (u32)6) & (u32)0x3F)));
            appendByte((u8)((u32)0x80 | (cp & (u32)0x3F)));
            return;
            }
        appendByte((u8)((u32)0xF0 | (cp >> (u32)18)));
        appendByte((u8)((u32)0x80 | ((cp >> (u32)12) & (u32)0x3F)));
        appendByte((u8)((u32)0x80 | ((cp >> (u32)6) & (u32)0x3F)));
        appendByte((u8)((u32)0x80 | (cp & (u32)0x3F)));
        }

    since("0.4") static String* withChar(u32 cp)
        {
        String* s = String.withCString((u8*)"");
        s.appendChar(cp);
        return s;
        }

    // The n-th CODE POINT (0-based); U+FFFD past the end. This is the 0.4
    // meaning of charAt — the 0.3 method of this name returned a BYTE and is
    // now byteAt. O(n): character positions are walked, not indexed.
    since("0.4") u32 charAt(u32 n)
        {
        u32 i = byteIndexOfChar(n);
        if (i >= _length)
            {
            return (u32)0xFFFD;
            }
        return charAtByte(i);
        }

    // `count` code points starting at char position `fromChar` — the char
    // twin of substringBytes. Clamps like the byte form: past-the-end is
    // empty, a long count stops at the end.
    since("0.4") String* substringChars(u32 fromChar, u32 count)
        {
        u32 b0 = byteIndexOfChar(fromChar);
        u32 i = b0;
        u32 seen = (u32)0;
        while (i < _length && seen < count)
            {
            i = nextCharByte(i);
            seen = seen + (u32)1;
            }
        return substringBytes(b0, i - b0);
        }

    // Strict well-formedness: every byte belongs to exactly one valid
    // sequence. The empty string is valid.
    since("0.4") bool isValidUtf8(void)
        {
        u32 i = (u32)0;
        while (i < _length)
            {
            u32 len = _decodeLenAt(i);
            if (len == (u32)0)
                {
                return false;
                }
            i = i + len;
            }
        return true;
        }

    // A copy in which each maximal invalid subpart is one U+FFFD — the
    // Unicode-recommended repair (what every browser does). Valid input
    // comes back byte-identical.
    since("0.4") String* sanitizedUtf8(void)
        {
        String* out = String.withCString((u8*)"");
        u8* b = _bytes;
        u32 i = (u32)0;
        while (i < _length)
            {
            u32 len = _decodeLenAt(i);
            if (len == (u32)0)
                {
                // Maximal subpart: the lead byte plus every continuation
                // byte that FOLLOWED it validly before the sequence failed.
                // One byte is consumed so far; extend over trailing continuations
                // that belong to no valid sequence of their own only when
                // the lead admitted them.
                u32 skip = (u32)1;
                u32 c0 = (u32)b[i];
                u32 admit = (u32)0;
                if (c0 >= (u32)0xC2 && c0 <= (u32)0xDF)
                    {
                    admit = (u32)1;
                    }
                if (c0 >= (u32)0xE0 && c0 <= (u32)0xEF)
                    {
                    admit = (u32)2;
                    }
                if (c0 >= (u32)0xF0 && c0 <= (u32)0xF4)
                    {
                    admit = (u32)3;
                    }
                while (skip <= admit && i + skip < _length && ((u32)b[i + skip] & (u32)0xC0) == (u32)0x80)
                    {
                    skip = skip + (u32)1;
                    }
                out.appendChar((u32)0xFFFD);
                i = i + skip;
                }
            else
                {
                out.appendBytes(&b[i], len);
                i = i + len;
                }
            }
        return out;
        }

    // ── Other encodings: transcode at the edge ───────────────────
    // Decode `n` bytes of `enc` into a (UTF-8) String. Malformed input
    // repairs to U+FFFD — unpaired UTF-16 surrogates, an odd trailing byte,
    // ASCII above 127, invalid UTF-8. Latin-1 cannot be malformed: a byte
    // IS its code point, which is the entire charm of Latin-1.
    since("0.4") static String* withEncodedBytes(u8* src, u32 n, StrEncoding enc)
        {
        String* out = String.withCString((u8*)"");
        if (enc == ENC_UTF8)
            {
            String* raw = String.withBytes(src, n);
            String* fixed = raw.sanitizedUtf8();
            out.setTo(fixed);
            return out;
            }
        if (enc == ENC_ASCII || enc == ENC_LATIN1)
            {
            u32 i = (u32)0;
            while (i < n)
                {
                u32 cp = (u32)src[i];
                if (enc == ENC_ASCII && cp > (u32)0x7F)
                    {
                    cp = (u32)0xFFFD;
                    }
                out.appendChar(cp);
                i = i + (u32)1;
                }
            return out;
            }
        // UTF-16, both orders. Units are read whole; an odd tail byte and
        // an unpaired surrogate each repair to one U+FFFD.
        u32 i = (u32)0;
        while (i + (u32)1 < n + (u32)1 && i + (u32)2 <= n)
            {
            u32 hi = (u32)0;
            if (enc == ENC_UTF16LE)
                {
                hi = (u32)src[i] | ((u32)src[i + (u32)1] << (u32)8);
                }
            else
                {
                hi = ((u32)src[i] << (u32)8) | (u32)src[i + (u32)1];
                }
            i = i + (u32)2;
            if (hi >= (u32)0xD800 && hi <= (u32)0xDBFF)
                {
                if (i + (u32)2 <= n)
                    {
                    u32 lo = (u32)0;
                    if (enc == ENC_UTF16LE)
                        {
                        lo = (u32)src[i] | ((u32)src[i + (u32)1] << (u32)8);
                        }
                    else
                        {
                        lo = ((u32)src[i] << (u32)8) | (u32)src[i + (u32)1];
                        }
                    if (lo >= (u32)0xDC00 && lo <= (u32)0xDFFF)
                        {
                        i = i + (u32)2;
                        u32 cp = (u32)0x10000 + ((hi - (u32)0xD800) << (u32)10) + (lo - (u32)0xDC00);
                        out.appendChar(cp);
                        continue;
                        }
                    }
                out.appendChar((u32)0xFFFD); // unpaired high surrogate
                continue;
                }
            if (hi >= (u32)0xDC00 && hi <= (u32)0xDFFF)
                {
                out.appendChar((u32)0xFFFD); // stray low surrogate
                continue;
                }
            out.appendChar(hi);
            }
        // odd trailing byte
        if (i < n)
            {
            out.appendChar((u32)0xFFFD);
            }
        return out;
        }
    }
