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

// Coder.xc — keyed archiving of an object graph to JSON, optionally gzipped.
// ===========================================================================
//
// The xc form of NSKeyedArchiver and NSKeyedUnarchiver, in one class. There is
// no separate archiver and unarchiver, and no un-keyed coding: a Coder is
// handed to `encodeWithCoder` while an archive is written and to
// `initWithCoder` while one is read (see Codable.xc), and the class methods
// below are the whole public entry point.
//
//     Data*   blob = Coder.archive(root, (u8)0);   // UTF-8 JSON
//     Data*   gz   = Coder.archive(root, (u8)9);   // the same JSON, gzipped
//     String* text = Coder.archiveJSON(root);
//
//     try   { Object* back = Coder.unarchive(gz); … }
//     catch (CoderError e) { Stdio.printf("%s\n", e.message().cString()); }
//
// ── The format ──────────────────────────────────────────────────────────────
//
// NSKeyedArchiver's object table, written as JSON:
//
//     {"$archiver":"Coder","$version":1,
//      "$top":{"root":{"$ref":1}},
//      "$objects":["$null",
//                  {"$class":"Point","x":3,"y":4,"next":{"$ref":2}},
//                  {"$class":"Point","x":5,"y":6,"next":{"$ref":1}}]}
//
// Every object is written ONCE, at its index in `$objects`, and referred to
// by index everywhere else, so an object shared by two parents stays shared
// and a cycle terminates. Index 0 is always "$null", the reference for null.
// Identity is the object's address: String and Number compare by value, and
// two equal strings that are distinct objects stay distinct.
//
// Scalars (`encodeI32`, `encodeBool`, …) are written inline in the owning
// object's entry. The library's own value types are written in a native JSON
// form instead of through `encodeWithCoder`:
//
//     String   "text"                                  a JSON string
//     Number   42  or  2.5                             a JSON number
//     Data     {"$class":"Data","$base64":"3q2+7w=="}
//     Array    {"$class":"Array","$items":[2,3,0]}     indexes into $objects
//     Set      {"$class":"Set","$items":[4,5]}
//     Map      {"$class":"Map","$keys":[6,7],"$values":[8,0]}
//
// A Number keeps its kind: a float is always written with a `.` or an
// exponent (`3.0`, `1e+300`), an integer never is. Integers are exact over
// the whole 64-bit range. A double is written in the shortest form that reads
// back as the same bits, and read back correctly rounded, so a round trip is
// exact. NaN and the infinities have no JSON spelling: inline they are the
// strings "NaN", "Infinity" and "-Infinity"; as a Number object they are
// {"$class":"Number","$double":"NaN"}. A String that is not valid UTF-8 cannot
// be a JSON string, and is written as {"$class":"String","$base64":…}.
//
// A key beginning with `$` is reserved for the format and written with an
// extra `$` in front, so a class may still use one. A subclass of String,
// Number, Data, Array, Map or Set is archived as that class.
//
// ── Compression ─────────────────────────────────────────────────────────────
//
// `archive(root, level)` with a level of 1 to 9 gzips the finished JSON once,
// at that level (RFC 1951 deflate in an RFC 1952 wrapper), and `unarchive`
// recognises the gzip magic by itself. Both directions are implemented here —
// LZ77 over hash chains, fixed and dynamic Huffman blocks, and a full inflate —
// so no target needs zlib. The output is what `gzip -d` expects, and `gunzip`
// reads what `gzip` writes; both are also public as `Coder.gzip` and
// `Coder.gunzip` for data that is not an archive.
//
// ── Errors ──────────────────────────────────────────────────────────────────
//
// `unarchive`, `unarchiveJSON` and `gunzip` throw a CoderError (see Error.xc)
// for input that is not JSON, not an archive, names a class the program does
// not have, fails its CRC or ends early. Inside `initWithCoder` the decode
// methods never throw: a missing key gives 0, false or null, as in Foundation,
// and a value of the wrong type is remembered and thrown by `unarchive` when
// the graph is finished.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every target except xt6502.

#if ARCH_6502
#error "Coder: archiving is not available on xt6502"
#endif

#import "Foundation.xc"
#import "Error.xc"
#import "Codable.xc"
#import "JSON.xc"

// ── Class names ─────────────────────────────────────────────────────────────
// The two calls that use the compiler's class-name table: the dynamic name of
// an object being written, and a fresh instance of a named class being read.
String* _coder_className(Object* obj)
    {
    return obj.className();
    }

Object* _coder_newInstance(String* name)
    {
    return Object.newInstanceOfClass(name);
    }

// Raw buffers (`new u8[n]`, `new u32[n]`) come from the object allocator with a
// refcount of 1 and no destructor, so releasing one frees it. Null-safe.
void _coder_free(pointer p)
    {
    __arc_release(p);
    }


// Deflate's length and distance alphabets (RFC 1951 §3.2.5).
u16 _coder_lenBase[29] = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                           35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
u8 _coder_lenExtra[29] = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                           3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
u16 _coder_distBase[30] = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                            257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                            8193, 12289, 16385, 24577 };
u8 _coder_distExtra[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                            7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
// Per compression level: how many chain links to follow, and the match length
// that ends the search early.
u16 _coder_chain[10] = { 0, 4, 8, 16, 16, 32, 128, 256, 1024, 4096 };
u16 _coder_nice[10] = { 0, 8, 16, 32, 16, 32, 128, 128, 258, 258 };
// The order a dynamic block lists its code-length code lengths in.
u8 _coder_clOrder[19] = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

// ═════════════════════════════════════════════════════════════════════════════
// CoderError — what unarchive and gunzip throw.
// ═════════════════════════════════════════════════════════════════════════════

class CoderError <Error>
    {
    String* _message;

    void init(String* message)
        {
        _message = message;
        }

    String* message(void)
        {
        return _message;
        }
    }

// ═════════════════════════════════════════════════════════════════════════════
// CoderDeflate — RFC 1951 compression.
// ═════════════════════════════════════════════════════════════════════════════
//
// LZ77 over a 32 KB window, with a hash of the next three bytes indexing
// chains of earlier positions. The level sets how far down a chain to look,
// when a match is long enough to stop looking, and whether a match is held
// back one byte in case the next position starts a longer one (lazy matching,
// levels 4 and up). The symbols are buffered and written in blocks of up to
// 16383; each block goes out as whichever of stored, fixed Huffman or dynamic
// Huffman is smallest for it.

class CoderDeflate
    {
    Data* _out;
    u32 _bitBuf;
    u32 _bitCnt;

    u8* _src;
    u32 _n;
    u32* _head;     // hash -> most recent position + 1
    u32* _prev;     // position & _wmask -> previous position + 1
    u32 _hbits;     // hash width in bits
    u32 _wmask;     // _prev size - 1

    u16* _sLit;     // literal byte, or match length
    u16* _sDist;    // 0 for a literal, else match distance
    u32 _nsym;
    u32 _symCap;    // a block is written when this many symbols are buffered
    u32 _blockStart;
    u32 _covered;   // input bytes the buffered symbols stand for

    u32 _maxChain;
    u32 _nice;
    bool _lazy;
    bool _storeOnly;

    // per-block Huffman work
    u32* _lf;       // literal/length frequencies [286]
    u32* _df;       // distance frequencies [30]
    u8* _ll;        // literal/length code lengths [288]
    u8* _dl;        // distance code lengths [30]
    u16* _lc;       // literal/length codes, bit-reversed [288]
    u16* _dc;       // distance codes, bit-reversed [30]
    u32* _cf;       // code-length code frequencies [19]
    u8* _cl;        // code-length code lengths [19]
    u16* _cc;       // code-length codes [19]
    u8* _all;       // literal and distance lengths back to back [316]
    u8* _rleSym;    // the run-length coded form of _all [316]
    u8* _rleExtra;
    u32 _nrle;

    // Huffman tree scratch
    u32* _hw;       // weights [2 * 288]
    u32* _hp;       // parents
    u8* _ha;        // alive
    u32* _hf;       // working frequencies [288]
    u16* _blCount;  // [16]
    u16* _next;     // [16]

    static u8* _lenTbl;     // match length 3..258 -> length code 0..28
    static u8* _distTbl;    // see _distCode

    void init(void)
        {
        _bitBuf = (u32)0;
        _bitCnt = (u32)0;
        _lf = new u32[288];
        _df = new u32[32];
        _ll = new u8[288];
        _dl = new u8[32];
        _lc = new u16[288];
        _dc = new u16[32];
        _cf = new u32[19];
        _cl = new u8[19];
        _cc = new u16[19];
        _all = new u8[320];
        _rleSym = new u8[320];
        _rleExtra = new u8[320];
        _hw = new u32[576];
        _hp = new u32[576];
        _ha = new u8[576];
        _hf = new u32[288];
        _blCount = new u16[16];
        _next = new u16[16];
        _sLit = (u16*)0;
        _sDist = (u16*)0;
        _head = (u32*)0;
        _prev = (u32*)0;
        CoderDeflate._tables();
        }

    void dealloc(void)
        {
        _coder_free((pointer)_lf);
        _coder_free((pointer)_df);
        _coder_free((pointer)_ll);
        _coder_free((pointer)_dl);
        _coder_free((pointer)_lc);
        _coder_free((pointer)_dc);
        _coder_free((pointer)_cf);
        _coder_free((pointer)_cl);
        _coder_free((pointer)_cc);
        _coder_free((pointer)_all);
        _coder_free((pointer)_rleSym);
        _coder_free((pointer)_rleExtra);
        _coder_free((pointer)_hw);
        _coder_free((pointer)_hp);
        _coder_free((pointer)_ha);
        _coder_free((pointer)_hf);
        _coder_free((pointer)_blCount);
        _coder_free((pointer)_next);
        _coder_free((pointer)_sLit);
        _coder_free((pointer)_sDist);
        _coder_free((pointer)_head);
        _coder_free((pointer)_prev);
        }

    static void _tables(void)
        {
        if (_lenTbl != (u8*)0)
            return;
        u8* lt = new u8[259];
        for (u32 c = (u32)0; c < (u32)28; c++)
            {
            u32 base = (u32)_coder_lenBase[c];
            u32 span = (u32)1 << (u32)_coder_lenExtra[c];
            for (u32 l = base; l < base + span && l < (u32)258; l++)
                lt[l] = (u8)c;
            }
        lt[258] = (u8)28;
        u8* dt = new u8[512];
        for (u32 c = (u32)0; c < (u32)30; c++)
            {
            u32 base = (u32)_coder_distBase[c];
            u32 span = (u32)1 << (u32)_coder_distExtra[c];
            for (u32 d = base; d < base + span; d++)
                {
                u32 k = d - (u32)1;
                if (k < (u32)256)
                    dt[k] = (u8)c;
                else
                    dt[(u32)256 + (k >> (u32)7)] = (u8)c;
                }
            }
        _lenTbl = lt;
        _distTbl = dt;
        }

    static u32 _distCode(u32 d)
        {
        u8* t = _distTbl;
        u32 k = d - (u32)1;
        if (k < (u32)256)
            return (u32)t[k];
        return (u32)t[(u32)256 + (k >> (u32)7)];
        }

    // ── Bits ─────────────────────────────────────────────────────────────
    void _put(u32 value, u32 count)
        {
        _bitBuf = _bitBuf | (value << _bitCnt);
        _bitCnt = _bitCnt + count;
        while (_bitCnt >= (u32)8)
            {
            _out.appendByte((u8)_bitBuf);
            _bitBuf = _bitBuf >> (u32)8;
            _bitCnt = _bitCnt - (u32)8;
            }
        }

    void _align(void)
        {
        if (_bitCnt > (u32)0)
            _out.appendByte((u8)_bitBuf);
        _bitBuf = (u32)0;
        _bitCnt = (u32)0;
        }

    static u32 _reverse(u32 code, u32 len)
        {
        u32 r = (u32)0;
        for (u32 i = (u32)0; i < len; i++)
            {
            r = (r << (u32)1) | (code & (u32)1);
            code = code >> (u32)1;
            }
        return r;
        }

    // ── Huffman code construction ────────────────────────────────────────
    // Code lengths for `n` symbols from their frequencies, none longer than
    // `maxBits`. At least two symbols always get a code, which keeps every
    // code complete (zlib does the same).
    void _lengths(u32* freq, u32 n, u32 maxBits, u8* out)
        {
        u32* f = _hf;
        u32 used = (u32)0;
        for (u32 i = (u32)0; i < n; i++)
            {
            f[i] = freq[i];
            if (f[i] != (u32)0)
                used = used + (u32)1;
            }
        for (u32 i = (u32)0; i < (u32)2 && used < (u32)2; i++)
            {
            if (f[i] == (u32)0)
                {
                f[i] = (u32)1;
                used = used + (u32)1;
                }
            }
        u32* w = _hw;
        u32* par = _hp;
        u8* alive = _ha;
        u32 none = (u32)0xFFFFFFFF;
        while (true)
            {
            u32 live = (u32)0;
            for (u32 i = (u32)0; i < n; i++)
                {
                w[i] = f[i];
                par[i] = none;
                alive[i] = (f[i] != (u32)0) ? (u8)1 : (u8)0;
                if (f[i] != (u32)0)
                    live = live + (u32)1;
                }
            u32 next = n;
            while (live > (u32)1)
                {
                u32 a = none;
                u32 b = none;
                for (u32 i = (u32)0; i < next; i++)
                    {
                    if (alive[i] == (u8)0)
                        continue;
                    if (a == none || w[i] < w[a])
                        {
                        b = a;
                        a = i;
                        }
                    else if (b == none || w[i] < w[b])
                        {
                        b = i;
                        }
                    }
                w[next] = w[a] + w[b];
                par[next] = none;
                alive[next] = (u8)1;
                par[a] = next;
                par[b] = next;
                alive[a] = (u8)0;
                alive[b] = (u8)0;
                next = next + (u32)1;
                live = live - (u32)1;
                }
            u32 deepest = (u32)0;
            for (u32 i = (u32)0; i < n; i++)
                {
                u32 depth = (u32)0;
                if (f[i] != (u32)0)
                    {
                    u32 j = i;
                    while (par[j] != none)
                        {
                        depth = depth + (u32)1;
                        j = par[j];
                        }
                    }
                out[i] = (u8)depth;
                if (depth > deepest)
                    deepest = depth;
                }
            if (deepest <= maxBits)
                return;
            // Too deep: flatten the distribution and build again.
            for (u32 i = (u32)0; i < n; i++)
                {
                if (f[i] != (u32)0)
                    f[i] = (f[i] >> (u32)1) + (u32)1;
                }
            }
        }

    // Canonical codes for the lengths (RFC 1951 §3.2.2), bit-reversed for
    // LSB-first output.
    void _codes(u8* len, u32 n, u16* code)
        {
        u16* bl = _blCount;
        u16* nx = _next;
        for (u32 i = (u32)0; i < (u32)16; i++)
            bl[i] = (u16)0;
        for (u32 i = (u32)0; i < n; i++)
            bl[len[i]] = bl[len[i]] + (u16)1;
        bl[0] = (u16)0;
        u32 c = (u32)0;
        for (u32 bits = (u32)1; bits < (u32)16; bits++)
            {
            c = (c + (u32)bl[bits - (u32)1]) << (u32)1;
            nx[bits] = (u16)c;
            }
        for (u32 i = (u32)0; i < n; i++)
            {
            u32 l = (u32)len[i];
            if (l != (u32)0)
                {
                code[i] = (u16)CoderDeflate._reverse((u32)nx[l], l);
                nx[l] = nx[l] + (u16)1;
                }
            }
        }

    static u32 _fixedLitLen(u32 sym)
        {
        if (sym < (u32)144)
            return (u32)8;
        if (sym < (u32)256)
            return (u32)9;
        if (sym < (u32)280)
            return (u32)7;
        return (u32)8;
        }

    void _rle(u32 total)
        {
        u8* all = _all;
        _nrle = (u32)0;
        u32 i = (u32)0;
        while (i < total)
            {
            u8 v = all[i];
            u32 run = (u32)1;
            while (i + run < total && all[i + run] == v)
                run = run + (u32)1;
            i = i + run;
            if (v == (u8)0)
                {
                while (run >= (u32)11)
                    {
                    u32 k = (run < (u32)138) ? run : (u32)138;
                    _rlePush((u8)18, (u8)(k - (u32)11));
                    run = run - k;
                    }
                if (run >= (u32)3)
                    {
                    _rlePush((u8)17, (u8)(run - (u32)3));
                    run = (u32)0;
                    }
                }
            else
                {
                _rlePush(v, (u8)0);
                run = run - (u32)1;
                while (run >= (u32)3)
                    {
                    u32 k = (run < (u32)6) ? run : (u32)6;
                    _rlePush((u8)16, (u8)(k - (u32)3));
                    run = run - k;
                    }
                }
            while (run > (u32)0)
                {
                _rlePush(v, (u8)0);
                run = run - (u32)1;
                }
            }
        }

    void _rlePush(u8 sym, u8 extra)
        {
        u8* s = _rleSym;
        u8* e = _rleExtra;
        s[_nrle] = sym;
        e[_nrle] = extra;
        _nrle = _nrle + (u32)1;
        }

    // ── Blocks ───────────────────────────────────────────────────────────
    void _emitSymbols(u16* lc, u8* ll, u16* dc, u8* dl)
        {
        u16* sl = _sLit;
        u16* sd = _sDist;
        u8* lt = _lenTbl;
        for (u32 s = (u32)0; s < _nsym; s++)
            {
            u32 d = (u32)sd[s];
            u32 v = (u32)sl[s];
            if (d == (u32)0)
                {
                _put((u32)lc[v], (u32)ll[v]);
                continue;
                }
            u32 c = (u32)lt[v];
            _put((u32)lc[(u32)257 + c], (u32)ll[(u32)257 + c]);
            u32 xb = (u32)_coder_lenExtra[c];
            if (xb != (u32)0)
                _put(v - (u32)_coder_lenBase[c], xb);
            u32 dcode = CoderDeflate._distCode(d);
            _put((u32)dc[dcode], (u32)dl[dcode]);
            xb = (u32)_coder_distExtra[dcode];
            if (xb != (u32)0)
                _put(d - (u32)_coder_distBase[dcode], xb);
            }
        _put((u32)lc[256], (u32)ll[256]);
        }

    void _writeStored(bool isLast)
        {
        u32 len = _covered;
        u32 at = _blockStart;
        u8* src = _src;
        while (true)
            {
            u32 chunk = (len < (u32)65535) ? len : (u32)65535;
            bool last = isLast && chunk == len;
            _put(last ? (u32)1 : (u32)0, (u32)1);
            _put((u32)0, (u32)2);
            _align();
            _out.appendByte((u8)(chunk & (u32)$FF));
            _out.appendByte((u8)(chunk >> (u32)8));
            _out.appendByte((u8)(~chunk & (u32)$FF));
            _out.appendByte((u8)((~chunk >> (u32)8) & (u32)$FF));
            _out.appendBytes(&src[at], chunk);
            at = at + chunk;
            len = len - chunk;
            if (len == (u32)0)
                break;
            }
        }

    void _flushBlock(bool isLast)
        {
        u32* lf = _lf;
        u32* df = _df;
        u16* sl = _sLit;
        u16* sd = _sDist;
        u8* lt = _lenTbl;
        for (u32 i = (u32)0; i < (u32)288; i++)
            lf[i] = (u32)0;
        for (u32 i = (u32)0; i < (u32)32; i++)
            df[i] = (u32)0;
        u32 extra = (u32)0;
        for (u32 s = (u32)0; s < _nsym; s++)
            {
            u32 d = (u32)sd[s];
            if (d == (u32)0)
                {
                lf[sl[s]] = lf[sl[s]] + (u32)1;
                continue;
                }
            u32 c = (u32)lt[sl[s]];
            lf[(u32)257 + c] = lf[(u32)257 + c] + (u32)1;
            u32 dcode = CoderDeflate._distCode(d);
            df[dcode] = df[dcode] + (u32)1;
            extra = extra + (u32)_coder_lenExtra[c] + (u32)_coder_distExtra[dcode];
            }
        lf[256] = (u32)1;

        // Cost of a stored block (header, alignment, LEN/NLEN per 64 KB).
        u32 chunks = _covered / (u32)65535 + (u32)1;
        u32 storedBits = chunks * (u32)(3 + 7 + 32) + _covered * (u32)8;
        if (_storeOnly)
            {
            _writeStored(isLast);
            _nextBlock();
            return;
            }

        // Fixed Huffman.
        u32 fixedBits = (u32)3 + extra;
        for (u32 i = (u32)0; i < (u32)286; i++)
            fixedBits = fixedBits + lf[i] * CoderDeflate._fixedLitLen(i);
        for (u32 i = (u32)0; i < (u32)30; i++)
            fixedBits = fixedBits + df[i] * (u32)5;

        // Dynamic Huffman.
        u8* ll = _ll;
        u8* dl = _dl;
        _lengths(lf, (u32)286, (u32)15, ll);
        _lengths(df, (u32)30, (u32)15, dl);
        u32 hlit = (u32)286;
        while (hlit > (u32)257 && ll[hlit - (u32)1] == (u8)0)
            hlit = hlit - (u32)1;
        u32 hdist = (u32)30;
        while (hdist > (u32)1 && dl[hdist - (u32)1] == (u8)0)
            hdist = hdist - (u32)1;
        u8* all = _all;
        for (u32 i = (u32)0; i < hlit; i++)
            all[i] = ll[i];
        for (u32 i = (u32)0; i < hdist; i++)
            all[hlit + i] = dl[i];
        _rle(hlit + hdist);
        u32* cf = _cf;
        for (u32 i = (u32)0; i < (u32)19; i++)
            cf[i] = (u32)0;
        u8* rs = _rleSym;
        u32 rleExtraBits = (u32)0;
        for (u32 i = (u32)0; i < _nrle; i++)
            {
            u8 sym = rs[i];
            cf[sym] = cf[sym] + (u32)1;
            if (sym == (u8)16)
                rleExtraBits = rleExtraBits + (u32)2;
            else if (sym == (u8)17)
                rleExtraBits = rleExtraBits + (u32)3;
            else if (sym == (u8)18)
                rleExtraBits = rleExtraBits + (u32)7;
            }
        u8* cl = _cl;
        _lengths(cf, (u32)19, (u32)7, cl);
        u32 hclen = (u32)19;
        while (hclen > (u32)4 && cl[_coder_clOrder[hclen - (u32)1]] == (u8)0)
            hclen = hclen - (u32)1;
        u32 dynBits = (u32)(3 + 5 + 5 + 4) + hclen * (u32)3 + rleExtraBits + extra;
        for (u32 i = (u32)0; i < (u32)19; i++)
            dynBits = dynBits + cf[i] * (u32)cl[i];
        for (u32 i = (u32)0; i < (u32)286; i++)
            dynBits = dynBits + lf[i] * (u32)ll[i];
        for (u32 i = (u32)0; i < (u32)30; i++)
            dynBits = dynBits + df[i] * (u32)dl[i];

        if (storedBits < fixedBits && storedBits < dynBits)
            {
            _writeStored(isLast);
            }
        else if (dynBits < fixedBits)
            {
            u16* lc = _lc;
            u16* dc = _dc;
            u16* cc = _cc;
            _codes(ll, (u32)286, lc);
            _codes(dl, (u32)30, dc);
            _codes(cl, (u32)19, cc);
            _put(isLast ? (u32)1 : (u32)0, (u32)1);
            _put((u32)2, (u32)2);
            _put(hlit - (u32)257, (u32)5);
            _put(hdist - (u32)1, (u32)5);
            _put(hclen - (u32)4, (u32)4);
            for (u32 i = (u32)0; i < hclen; i++)
                _put((u32)cl[_coder_clOrder[i]], (u32)3);
            u8* re = _rleExtra;
            for (u32 i = (u32)0; i < _nrle; i++)
                {
                u32 sym = (u32)rs[i];
                _put((u32)cc[sym], (u32)cl[sym]);
                if (sym == (u32)16)
                    _put((u32)re[i], (u32)2);
                else if (sym == (u32)17)
                    _put((u32)re[i], (u32)3);
                else if (sym == (u32)18)
                    _put((u32)re[i], (u32)7);
                }
            _emitSymbols(lc, ll, dc, dl);
            }
        else
            {
            u8* fll = _ll;
            u8* fdl = _dl;
            u16* lc = _lc;
            u16* dc = _dc;
            for (u32 i = (u32)0; i < (u32)288; i++)
                fll[i] = (u8)CoderDeflate._fixedLitLen(i);
            for (u32 i = (u32)0; i < (u32)30; i++)
                fdl[i] = (u8)5;
            _codes(fll, (u32)288, lc);
            _codes(fdl, (u32)30, dc);
            _put(isLast ? (u32)1 : (u32)0, (u32)1);
            _put((u32)1, (u32)2);
            _emitSymbols(lc, fll, dc, fdl);
            }
        _nextBlock();
        }

    void _nextBlock(void)
        {
        _blockStart = _blockStart + _covered;
        _covered = (u32)0;
        _nsym = (u32)0;
        }

    void _literal(u8 b)
        {
        u16* sl = _sLit;
        u16* sd = _sDist;
        sl[_nsym] = (u16)b;
        sd[_nsym] = (u16)0;
        _nsym = _nsym + (u32)1;
        _covered = _covered + (u32)1;
        if (_nsym == _symCap)
            _flushBlock(false);
        }

    void _match(u32 len, u32 dist)
        {
        u16* sl = _sLit;
        u16* sd = _sDist;
        sl[_nsym] = (u16)len;
        sd[_nsym] = (u16)dist;
        _nsym = _nsym + (u32)1;
        _covered = _covered + len;
        if (_nsym == _symCap)
            _flushBlock(false);
        }

    // ── LZ77 ─────────────────────────────────────────────────────────────
    u32 _hash(u32 i)
        {
        u8* s = _src;
        u32 v = ((u32)s[i] << (u32)16) | ((u32)s[i + (u32)1] << (u32)8) | (u32)s[i + (u32)2];
        return (v * (u32)2654435761) >> ((u32)32 - _hbits);
        }

    void _insert(u32 i)
        {
        if (i + (u32)3 > _n)
            return;
        u32 h = _hash(i);
        u32* head = _head;
        u32* prev = _prev;
        prev[i & _wmask] = head[h];
        head[h] = i + (u32)1;
        }

    u32 _foundLen;
    u32 _foundDist;

    // The longest earlier match for position i, into _foundLen/_foundDist
    // (a length below 3 means none). Call before inserting i.
    void _find(u32 i)
        {
        _foundLen = (u32)0;
        _foundDist = (u32)0;
        if (i + (u32)3 > _n)
            return;
        u8* s = _src;
        u32* prev = _prev;
        u32* head = _head;
        u32 limit = (i > (u32)32768) ? i - (u32)32768 : (u32)0;
        u32 maxLen = _n - i;
        if (maxLen > (u32)258)
            maxLen = (u32)258;
        u32 best = (u32)2;
        u32 cand = head[_hash(i)];
        u32 chain = _maxChain;
        while (cand != (u32)0 && chain > (u32)0)
            {
            u32 c = cand - (u32)1;
            if (c < limit)
                break;
            chain = chain - (u32)1;
            if (s[c + best] == s[i + best] && s[c] == s[i])
                {
                u32 l = (u32)0;
                while (l < maxLen && s[c + l] == s[i + l])
                    l = l + (u32)1;
                if (l > best)
                    {
                    best = l;
                    _foundLen = l;
                    _foundDist = i - c;
                    if (l >= _nice || l == maxLen)
                        break;
                    }
                }
            cand = prev[c & _wmask];
            }
        }

    void _compress(void)
        {
        if (_storeOnly)
            {
            _covered = _n;
            _flushBlock(true);
            _align();
            return;
            }
        // Every table is sized to the input, up to the 32 KB window: a short
        // archive needs a few KB here, not a quarter of a megabyte.
        u32 wsize = (u32)512;
        _hbits = (u32)9;
        while (wsize < _n && wsize < (u32)32768)
            {
            wsize = wsize * (u32)2;
            _hbits = _hbits + (u32)1;
            }
        _wmask = wsize - (u32)1;
        u32 hsize = (u32)1 << _hbits;
        _head = new u32[hsize];
        _prev = new u32[wsize];
        u32* head = _head;
        for (u32 i = (u32)0; i < hsize; i++)
            head[i] = (u32)0;
        _symCap = (_n < (u32)16383) ? _n + (u32)1 : (u32)16383;
        _sLit = new u16[_symCap];
        _sDist = new u16[_symCap];
        u8* s = _src;
        u32 i = (u32)0;
        if (!_lazy)
            {
            while (i < _n)
                {
                _find(i);
                if (_foundLen >= (u32)3)
                    {
                    u32 len = _foundLen;
                    _match(len, _foundDist);
                    for (u32 k = (u32)0; k < len; k++)
                        _insert(i + k);
                    i = i + len;
                    }
                else
                    {
                    _insert(i);
                    _literal(s[i]);
                    i = i + (u32)1;
                    }
                }
            }
        else
            {
            bool havePrev = false;
            u32 prevLen = (u32)0;
            u32 prevDist = (u32)0;
            while (i < _n)
                {
                u32 len = (u32)0;
                u32 dist = (u32)0;
                if (!havePrev || prevLen < _nice)
                    {
                    _find(i);
                    len = _foundLen;
                    dist = _foundDist;
                    }
                _insert(i);
                if (havePrev)
                    {
                    if (prevLen >= (u32)3 && len <= prevLen)
                        {
                        // the held match wins; it starts at i - 1
                        _match(prevLen, prevDist);
                        u32 end = i - (u32)1 + prevLen;
                        for (u32 k = i + (u32)1; k < end; k++)
                            _insert(k);
                        i = end;
                        havePrev = false;
                        continue;
                        }
                    _literal(s[i - (u32)1]);
                    }
                prevLen = len;
                prevDist = dist;
                havePrev = true;
                i = i + (u32)1;
                }
            if (havePrev)
                {
                if (prevLen >= (u32)3)
                    _match(prevLen, prevDist);
                else
                    _literal(s[_n - (u32)1]);
                }
            }
        _flushBlock(true);
        _align();
        }

    // Raw deflate of `n` bytes at `src`, appended to `out`.
    static void deflate(u8* src, u32 n, u8 level, Data* out)
        {
        CoderDeflate* z = new CoderDeflate();
        z._out = out;
        z._src = src;
        z._n = n;
        z._storeOnly = level == (u8)0;
        u32 lv = (u32)level;
        if (lv > (u32)9)
            lv = (u32)9;
        z._maxChain = (u32)_coder_chain[lv];
        z._nice = (u32)_coder_nice[lv];
        z._lazy = lv >= (u32)4;
        z._compress();
        }
    }

// ═════════════════════════════════════════════════════════════════════════════
// CoderInflate — RFC 1951 decompression: stored, fixed and dynamic blocks.
// ═════════════════════════════════════════════════════════════════════════════
//
// Canonical Huffman codes are decoded a bit at a time from per-length counts
// (the method of zlib's puff.c). A read past the end of the input, or anything
// the format does not allow, stops decoding with a reason in _error.

class CoderInflate
    {
    u8* _src;
    u32 _n;
    u32 _pos;
    u32 _bitBuf;
    u32 _bitCnt;
    string _error;

    u8* _out;
    u32 _len;
    u32 _cap;

    u16* _lcount;   // [16]
    u16* _lsym;     // [288]
    u16* _dcount;   // [16]
    u16* _dsym;     // [32]
    u16* _offs;     // [16]
    u8* _lengths;   // [320]

    void init(void)
        {
        _error = (string)0;
        _lcount = new u16[16];
        _lsym = new u16[288];
        _dcount = new u16[16];
        _dsym = new u16[32];
        _offs = new u16[16];
        _lengths = new u8[320];
        _cap = (u32)1024;
        _out = new u8[_cap];
        _len = (u32)0;
        }

    void dealloc(void)
        {
        _coder_free((pointer)_lcount);
        _coder_free((pointer)_lsym);
        _coder_free((pointer)_dcount);
        _coder_free((pointer)_dsym);
        _coder_free((pointer)_offs);
        _coder_free((pointer)_lengths);
        _coder_free((pointer)_out);
        }

    void _fail(string why)
        {
        if (_error == (string)0)
            _error = why;
        }

    u32 _bits(u32 need)
        {
        u8* s = _src;
        while (_bitCnt < need)
            {
            if (_pos >= _n)
                {
                _fail("compressed data ends early");
                return (u32)0;
                }
            _bitBuf = _bitBuf | ((u32)s[_pos] << _bitCnt);
            _pos = _pos + (u32)1;
            _bitCnt = _bitCnt + (u32)8;
            }
        u32 v = _bitBuf & (((u32)1 << need) - (u32)1);
        _bitBuf = _bitBuf >> need;
        _bitCnt = _bitCnt - need;
        return v;
        }

    void _emit(u8 b)
        {
        if (_len >= _cap)
            {
            u32 cap = _cap * (u32)2;
            u8* fresh = new u8[cap];
            u8* old = _out;
            for (u32 i = (u32)0; i < _len; i++)
                fresh[i] = old[i];
            _out = fresh;
            _cap = cap;
            _coder_free((pointer)old);
            }
        u8* o = _out;
        o[_len] = b;
        _len = _len + (u32)1;
        }

    // Decoding tables from code lengths. False when the lengths over-subscribe
    // the code space; an incomplete code is accepted and fails only if an
    // unused code turns up.
    bool _build(u16* count, u16* sym, u8* lengths, u32 n)
        {
        for (u32 l = (u32)0; l < (u32)16; l++)
            count[l] = (u16)0;
        for (u32 s = (u32)0; s < n; s++)
            count[lengths[s]] = count[lengths[s]] + (u16)1;
        if ((u32)count[0] == n)
            return true;
        i32 left = (i32)1;
        for (u32 l = (u32)1; l < (u32)16; l++)
            {
            left = left * (i32)2 - (i32)count[l];
            if (left < (i32)0)
                return false;
            }
        u16* offs = _offs;
        offs[1] = (u16)0;
        for (u32 l = (u32)1; l < (u32)15; l++)
            offs[l + (u32)1] = offs[l] + count[l];
        for (u32 s = (u32)0; s < n; s++)
            {
            u32 l = (u32)lengths[s];
            if (l != (u32)0)
                {
                sym[offs[l]] = (u16)s;
                offs[l] = offs[l] + (u16)1;
                }
            }
        return true;
        }

    u32 _decode(u16* count, u16* sym)
        {
        u32 code = (u32)0;
        u32 first = (u32)0;
        u32 index = (u32)0;
        for (u32 l = (u32)1; l < (u32)16; l++)
            {
            code = code | _bits((u32)1);
            if (_error != (string)0)
                return (u32)0xFFFF;
            u32 c = (u32)count[l];
            if (code < first + c)
                return (u32)sym[index + (code - first)];
            index = index + c;
            first = (first + c) << (u32)1;
            code = code << (u32)1;
            }
        _fail("invalid Huffman code");
        return (u32)0xFFFF;
        }

    void _stored(void)
        {
        _bitBuf = (u32)0;
        _bitCnt = (u32)0;
        if (_pos + (u32)4 > _n)
            {
            _fail("compressed data ends early");
            return;
            }
        u8* s = _src;
        u32 len = (u32)s[_pos] | ((u32)s[_pos + (u32)1] << (u32)8);
        u32 nlen = (u32)s[_pos + (u32)2] | ((u32)s[_pos + (u32)3] << (u32)8);
        _pos = _pos + (u32)4;
        if (len != (~nlen & (u32)$FFFF))
            {
            _fail("stored block length check failed");
            return;
            }
        if (_pos + len > _n)
            {
            _fail("compressed data ends early");
            return;
            }
        for (u32 i = (u32)0; i < len; i++)
            _emit(s[_pos + i]);
        _pos = _pos + len;
        }

    void _codes(void)
        {
        while (true)
            {
            u32 sym = _decode(_lcount, _lsym);
            if (_error != (string)0)
                return;
            if (sym < (u32)256)
                {
                _emit((u8)sym);
                continue;
                }
            if (sym == (u32)256)
                return;
            sym = sym - (u32)257;
            if (sym >= (u32)29)
                {
                _fail("invalid length code");
                return;
                }
            u32 len = (u32)_coder_lenBase[sym] + _bits((u32)_coder_lenExtra[sym]);
            u32 ds = _decode(_dcount, _dsym);
            if (_error != (string)0)
                return;
            if (ds >= (u32)30)
                {
                _fail("invalid distance code");
                return;
                }
            u32 dist = (u32)_coder_distBase[ds] + _bits((u32)_coder_distExtra[ds]);
            if (_error != (string)0)
                return;
            if (dist > _len)
                {
                _fail("distance reaches before the start of the data");
                return;
                }
            for (u32 k = (u32)0; k < len; k++)
                {
                u8* o = _out;
                _emit(o[_len - dist]);
                }
            }
        }

    void _fixed(void)
        {
        u8* l = _lengths;
        for (u32 i = (u32)0; i < (u32)288; i++)
            l[i] = (u8)CoderDeflate._fixedLitLen(i);
        _build(_lcount, _lsym, l, (u32)288);
        for (u32 i = (u32)0; i < (u32)30; i++)
            l[i] = (u8)5;
        _build(_dcount, _dsym, l, (u32)30);
        _codes();
        }

    void _dynamic(void)
        {
        u32 nlen = _bits((u32)5) + (u32)257;
        u32 ndist = _bits((u32)5) + (u32)1;
        u32 ncode = _bits((u32)4) + (u32)4;
        if (_error != (string)0)
            return;
        if (nlen > (u32)286 || ndist > (u32)30)
            {
            _fail("bad dynamic block counts");
            return;
            }
        u8* l = _lengths;
        for (u32 i = (u32)0; i < (u32)19; i++)
            l[i] = (u8)0;
        for (u32 i = (u32)0; i < ncode; i++)
            l[_coder_clOrder[i]] = (u8)_bits((u32)3);
        if (_error != (string)0)
            return;
        if (!_build(_lcount, _lsym, l, (u32)19))
            {
            _fail("bad code-length code");
            return;
            }
        u32 total = nlen + ndist;
        u32 index = (u32)0;
        while (index < total)
            {
            u32 sym = _decode(_lcount, _lsym);
            if (_error != (string)0)
                return;
            if (sym < (u32)16)
                {
                l[index] = (u8)sym;
                index = index + (u32)1;
                continue;
                }
            u8 value = (u8)0;
            u32 rep = (u32)0;
            if (sym == (u32)16)
                {
                if (index == (u32)0)
                    {
                    _fail("repeat with no previous length");
                    return;
                    }
                value = l[index - (u32)1];
                rep = (u32)3 + _bits((u32)2);
                }
            else if (sym == (u32)17)
                {
                rep = (u32)3 + _bits((u32)3);
                }
            else
                {
                rep = (u32)11 + _bits((u32)7);
                }
            if (index + rep > total)
                {
                _fail("too many code lengths");
                return;
                }
            for (u32 k = (u32)0; k < rep; k++)
                {
                l[index] = value;
                index = index + (u32)1;
                }
            }
        if (_error != (string)0)
            return;
        if (l[256] == (u8)0)
            {
            _fail("no end-of-block code");
            return;
            }
        if (!_build(_lcount, _lsym, l, nlen))
            {
            _fail("bad literal/length code");
            return;
            }
        if (!_build(_dcount, _dsym, &l[nlen], ndist))
            {
            _fail("bad distance code");
            return;
            }
        _codes();
        }

    // Inflate from `src`. Returns the number of input bytes consumed; the
    // result is in _out/_len, or _error says why not.
    u32 run(u8* src, u32 n)
        {
        _src = src;
        _n = n;
        _pos = (u32)0;
        _bitBuf = (u32)0;
        _bitCnt = (u32)0;
        u32 last = (u32)0;
        while (last == (u32)0)
            {
            last = _bits((u32)1);
            u32 type = _bits((u32)2);
            if (_error != (string)0)
                break;
            if (type == (u32)0)
                _stored();
            else if (type == (u32)1)
                _fixed();
            else if (type == (u32)2)
                _dynamic();
            else
                _fail("invalid block type");
            if (_error != (string)0)
                break;
            }
        return _pos;
        }
    }

// ═════════════════════════════════════════════════════════════════════════════
// Coder
// ═════════════════════════════════════════════════════════════════════════════

u8* _coder_b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

class Coder
    {
    bool _decoding;

    // archiving
    Array* _records;    // one JSON text per $objects entry
    Array* _keep;       // every archived object, so no address is reused
    pointer* _idKeys;   // object address -> index in $objects
    u32* _idVals;
    u32 _idCap;
    u32 _idCount;
    String* _cur;       // the entry being written

    // unarchiving
    Array* _nodes;      // the parsed $objects
    Array* _made;       // index -> decoded object
    u8* _state;         // index -> 0 not started, 1 decoded or in progress
    _JSONNode* _rec;    // the entry being read
    String* _error;     // first problem found while decoding

    static u32* _crcTable;

    void init(void)
        {
        _decoding = false;
        _idKeys = (pointer*)0;
        _idVals = (u32*)0;
        _idCap = (u32)0;
        _idCount = (u32)0;
        _state = (u8*)0;
        }

    void dealloc(void)
        {
        _coder_free((pointer)_idKeys);
        _coder_free((pointer)_idVals);
        _coder_free((pointer)_state);
        }

    // ═════════════════════════════════════════════════════════════════════
    // Archiving
    // ═════════════════════════════════════════════════════════════════════

    // The archive of `root` as UTF-8 JSON, or gzipped at `compression` 1-9.
    // Compression 0 is plain JSON.
    static Data* archive(Object* root, u8 compression)
        {
        String* json = Coder.archiveJSON(root);
        if (compression == (u8)0)
            return Data.withString(json);
        u8 level = (compression > (u8)9) ? (u8)9 : compression;
        return Coder._gzipBytes(json.cString(), json.byteLength(), level);
        }

    static String* archiveJSON(Object* root)
        {
        Coder* c = new Coder();
        c._records = new Array();
        c._keep = new Array();
        c._records.add(String.withCString("\"$null\""));
        c._keep.add((Object*)0);
        u32 top = c._ref(root);
        String* out = String.withCString("{\"$archiver\":\"Coder\",\"$version\":1,\"$top\":{\"root\":{\"$ref\":");
        out.append(String.withU32(top));
        out.appendCString("}},\"$objects\":[");
        u32 n = c._records.count();
        for (u32 i = (u32)0; i < n; i++)
            {
            if (i != (u32)0)
                out.appendByte((u8)',');
            out.append((String*)c._records.get(i));
            }
        out.appendCString("]}");
        return out;
        }

    // ── Keyed encoding (from inside encodeWithCoder) ─────────────────────
    void encodeObject(Object* obj, string key)
        {
        if (!_field(key))
            return;
        u32 idx = _ref(obj);
        _cur.appendCString("{\"$ref\":");
        _cur.append(String.withU32(idx));
        _cur.appendByte((u8)'}');
        }

    void encodeBool(bool v, string key)
        {
        if (!_field(key))
            return;
        _cur.appendCString(v ? "true" : "false");
        }

    void encodeI32(i32 v, string key)
        {
        if (!_field(key))
            return;
        _cur.append(String.withI32(v));
        }

    void encodeU32(u32 v, string key)
        {
        if (!_field(key))
            return;
        _cur.append(String.withU32(v));
        }

    void encodeI64(i64 v, string key)
        {
        if (!_field(key))
            return;
        _cur.append(String.withI64(v));
        }

    void encodeU64(u64 v, string key)
        {
        if (!_field(key))
            return;
        _cur.append(String.withU64(v));
        }

    void encodeFloat(float v, string key)
        {
        if (!_field(key))
            return;
        Coder._appendDoubleValue(_cur, (double)v, true);
        }

    void encodeDouble(double v, string key)
        {
        if (!_field(key))
            return;
        Coder._appendDoubleValue(_cur, v, false);
        }

    // Start `"key":` in the current entry. False when not archiving.
    bool _field(string key)
        {
        if (_decoding || _cur == 0)
            return false;
        _cur.appendByte((u8)',');
        Coder._appendKey(_cur, key);
        _cur.appendByte((u8)':');
        return true;
        }

    static void _appendKey(String* s, string key)
        {
        s.appendByte((u8)'"');
        if (key[0] == (u8)'$')
            s.appendByte((u8)'$');
        JSON._appendEscaped(s, key, String._cstringLen(key));
        s.appendByte((u8)'"');
        }

    static void _appendDoubleValue(String* s, double v, bool single)
        {
        u64 bits = _json_dbits(v);
        if (((bits >> (u64)52) & (u64)0x7FF) == (u64)0x7FF)
            {
            if ((bits & (u64)0x000FFFFFFFFFFFFF) != (u64)0)
                s.appendCString("\"NaN\"");
            else if ((bits >> (u64)63) != (u64)0)
                s.appendCString("\"-Infinity\"");
            else
                s.appendCString("\"Infinity\"");
            return;
            }
        _json_appendDouble(s, v, single);
        }



    // ── The object table ─────────────────────────────────────────────────
    static u32 _addrHash(pointer p)
        {
        u32 a = (u32)p;
        a = a ^ (a >> (u32)16);
        a = a * (u32)2246822519;
        a = a ^ (a >> (u32)13);
        return a;
        }

    u32 _idFind(pointer p)
        {
        if (_idCap == (u32)0)
            return (u32)0xFFFFFFFF;
        pointer* keys = _idKeys;
        u32* vals = _idVals;
        u32 mask = _idCap - (u32)1;
        u32 i = Coder._addrHash(p) & mask;
        while (keys[i] != (pointer)0)
            {
            if (keys[i] == p)
                return vals[i];
            i = (i + (u32)1) & mask;
            }
        return (u32)0xFFFFFFFF;
        }

    void _idPut(pointer p, u32 v)
        {
        if ((_idCount + (u32)1) * (u32)2 > _idCap)
            {
            u32 cap = (_idCap == (u32)0) ? (u32)64 : _idCap * (u32)2;
            pointer* oldKeys = _idKeys;
            u32* oldVals = _idVals;
            u32 oldCap = _idCap;
            pointer* nk = new pointer[cap];
            u32* nv = new u32[cap];
            for (u32 i = (u32)0; i < cap; i++)
                nk[i] = (pointer)0;
            _idKeys = nk;
            _idVals = nv;
            _idCap = cap;
            _idCount = (u32)0;
            for (u32 i = (u32)0; i < oldCap; i++)
                {
                if (oldKeys[i] != (pointer)0)
                    _idPut(oldKeys[i], oldVals[i]);
                }
            _coder_free((pointer)oldKeys);
            _coder_free((pointer)oldVals);
            }
        pointer* keys = _idKeys;
        u32* vals = _idVals;
        u32 mask = _idCap - (u32)1;
        u32 i = Coder._addrHash(p) & mask;
        while (keys[i] != (pointer)0)
            i = (i + (u32)1) & mask;
        keys[i] = p;
        vals[i] = v;
        _idCount = _idCount + (u32)1;
        }

    // The $objects index of `obj`, writing its entry the first time.
    u32 _ref(Object* obj)
        {
        if (obj == 0)
            return (u32)0;
        u32 idx = _idFind((pointer)obj);
        if (idx != (u32)0xFFFFFFFF)
            return idx;
        idx = _records.count();
        _records.add((Object*)0);
        _keep.add(obj);
        _idPut((pointer)obj, idx);
        String* saved = _cur;
        _cur = String.withCString("");
        _write(obj);
        _records.set(idx, _cur);
        _cur = saved;
        return idx;
        }

    // One $objects entry into _cur.
    void _write(Object* obj)
        {
        String* str = (String* ?)obj;
        if (str != 0)
            {
            if (str.isValidUtf8())
                {
                JSON._appendString(_cur, str.cString(), str.byteLength());
                }
            else
                {
                _cur.appendCString("{\"$class\":\"String\",\"$base64\":\"");
                Coder._appendBase64(_cur, str.cString(), str.byteLength());
                _cur.appendCString("\"}");
                }
            return;
            }
        Number* num = (Number* ?)obj;
        if (num != 0)
            {
            if (!num.isFloat())
                {
                _cur.append(String.withI64(num.asI64()));
                return;
                }
            double d = num.asDouble();
            u64 bits = _json_dbits(d);
            if (((bits >> (u64)52) & (u64)0x7FF) == (u64)0x7FF)
                {
                _cur.appendCString("{\"$class\":\"Number\",\"$double\":");
                Coder._appendDoubleValue(_cur, d, false);
                _cur.appendByte((u8)'}');
                return;
                }
            _json_appendDouble(_cur, d, false);
            return;
            }
        Data* data = (Data* ?)obj;
        if (data != 0)
            {
            _cur.appendCString("{\"$class\":\"Data\",\"$base64\":\"");
            Coder._appendBase64(_cur, data.bytes(), data.length());
            _cur.appendCString("\"}");
            return;
            }
        Array* arr = (Array* ?)obj;
        if (arr != 0)
            {
            _cur.appendCString("{\"$class\":\"Array\",\"$items\":");
            _writeRefs(arr);
            _cur.appendByte((u8)'}');
            return;
            }
        Map* map = (Map* ?)obj;
        if (map != 0)
            {
            _cur.appendCString("{\"$class\":\"Map\",\"$keys\":");
            _writeRefs(map.allKeys());
            _cur.appendCString(",\"$values\":");
            _writeRefs(map.allValues());
            _cur.appendByte((u8)'}');
            return;
            }
        Set* set = (Set* ?)obj;
        if (set != 0)
            {
            _cur.appendCString("{\"$class\":\"Set\",\"$items\":");
            _writeRefs(set.allObjects());
            _cur.appendByte((u8)'}');
            return;
            }
        // Any other class: its name, then whatever its encodeWithCoder writes.
        // Each field adds its own leading ',', which the name has already
        // made legal.
        String* name = _coder_className(obj);
        _cur.appendCString("{\"$class\":");
        if (name == 0)
            _cur.appendCString("null");
        else
            JSON._appendString(_cur, name.cString(), name.byteLength());
        obj.encodeWithCoder(self);
        _cur.appendByte((u8)'}');
        }

    // `[i, j, …]` — each element's index, written after the elements (which
    // may need entries of their own) have been placed.
    void _writeRefs(Array* items)
        {
        u32 n = items.count();
        String* refs = String.withCString("[");
        for (u32 i = (u32)0; i < n; i++)
            {
            if (i != (u32)0)
                refs.appendByte((u8)',');
            refs.append(String.withU32(_ref(items.get(i))));
            }
        refs.appendByte((u8)']');
        _cur.append(refs);
        }

    // ═════════════════════════════════════════════════════════════════════
    // Unarchiving
    // ═════════════════════════════════════════════════════════════════════

    // The root object of an archive written by `archive`, compressed or not.
    static Object* unarchive(Data* data) throws
        {
        if (data == 0)
            throw new CoderError(String.withCString("Coder: no data"));
        u8* b = data.bytes();
        u32 n = data.length();
        if (n >= (u32)2 && b[0] == (u8)$1F && b[1] == (u8)$8B)
            {
            Data* plain = Coder.gunzip(data);
            return Coder._unarchiveBytes(plain.bytes(), plain.length());
            }
        return Coder._unarchiveBytes(b, n);
        }

    static Object* unarchiveJSON(String* json) throws
        {
        if (json == 0)
            throw new CoderError(String.withCString("Coder: no JSON"));
        return Coder._unarchiveBytes(json.cString(), json.byteLength());
        }

    static Object* _unarchiveBytes(u8* p, u32 n) throws
        {
        _JSONReader* parser = new _JSONReader();
        _JSONNode* doc = parser.parse(p, n);
        if (doc == 0)
            throw new CoderError(parser._error);
        _JSONNode* archiver = doc.field("$archiver", false);
        if (archiver == 0 || !archiver.isString("Coder"))
            throw new CoderError(String.withCString("Coder: not a Coder archive"));
        _JSONNode* version = doc.field("$version", false);
        if (version == 0 || !version.isInteger())
            throw new CoderError(String.withCString("Coder: the archive has no version"));
        if (!version.textIs("1"))
            throw new CoderError(String.withCString("Coder: the archive's version is not 1"));
        _JSONNode* objects = doc.field("$objects", false);
        _JSONNode* top = doc.field("$top", false);
        if (objects == 0 || objects.kind != JK_ARRAY || top == 0)
            throw new CoderError(String.withCString("Coder: the archive has no object table"));
        _JSONNode* rootRef = top.field("root", false);
        if (rootRef == 0)
            throw new CoderError(String.withCString("Coder: the archive has no root"));

        Coder* c = new Coder();
        c._decoding = true;
        c._nodes = objects.items;
        u32 count = objects.items.count();
        c._made = Array.withCapacity(count);
        u8* state = new u8[count + (u32)1];
        for (u32 i = (u32)0; i < count; i++)
            {
            c._made.add((Object*)0);
            state[i] = (u8)0;
            }
        c._state = state;
        u32 idx = c._refIndex(rootRef, "root");
        Object* root = (Object*)0;
        if (c._error == 0)
            root = c._object(idx);
        if (c._error != 0)
            throw new CoderError(c._error);
        return root;
        }

    void _fail(string what, string key, string why)
        {
        if (_error != 0)
            return;
        _error = String.withCString("Coder: ");
        _error.appendCString(what);
        if (key != (string)0)
            {
            _error.appendCString(" '");
            _error.appendCString(key);
            _error.appendCString("'");
            }
        _error.appendCString(why);
        }

    // The index a `{"$ref":n}` node points at, or 0 (null) with an error set.
    u32 _refIndex(_JSONNode* node, string key)
        {
        _JSONNode* r = node.field("$ref", false);
        if (r == 0 || !r.isInteger())
            {
            _fail("value for key", key, " is not an object reference");
            return (u32)0;
            }
        return Coder._indexOf(r);
        }

    // An integer node as an index; out-of-range values become 0xFFFFFFFF,
    // which the caller's bounds check rejects.
    static u32 _indexOf(_JSONNode* r)
        {
        if (r == 0 || !r.isInteger())
            return (u32)0xFFFFFFFF;
        u8* b = r.text.cString();
        u32 n = r.text.byteLength();
        if (b[0] == (u8)'-' || n > (u32)9)
            return (u32)0xFFFFFFFF;
        u32 v = (u32)0;
        for (u32 i = (u32)0; i < n; i++)
            v = v * (u32)10 + (u32)(b[i] - (u8)'0');
        return v;
        }

    // The object at $objects index `idx`, decoding it the first time.
    Object* _object(u32 idx)
        {
        if (idx == (u32)0)
            return (Object*)0;
        if (idx >= _nodes.count())
            {
            _fail("reference out of range", (string)0, "");
            return (Object*)0;
            }
        u8* state = _state;
        if (state[idx] != (u8)0)
            return _made.get(idx);
        state[idx] = (u8)1;
        _JSONNode* node = (_JSONNode*)_nodes.get(idx);
        if (node.kind == JK_STRING)
            {
            Object* s = String.withBytes(node.text.cString(), node.text.byteLength());
            _made.set(idx, s);
            return s;
            }
        if (node.kind == JK_NUMBER)
            {
            Object* v = (Object*)JSON._numberOf(node);
            _made.set(idx, v);
            return v;
            }
        if (node.kind != JK_OBJECT)
            {
            _fail("an entry in $objects is not a value", (string)0, "");
            return (Object*)0;
            }
        _JSONNode* cls = node.field("$class", false);
        if (cls == 0 || cls.kind != JK_STRING)
            {
            _fail("an entry in $objects has no class", (string)0, "");
            return (Object*)0;
            }
        if (cls.isString("String") || cls.isString("Data"))
            {
            _JSONNode* b64 = node.field("$base64", false);
            Data* bytes = (b64 == 0) ? (Data*)0 : Coder._decodeBase64(b64.text);
            if (bytes == 0)
                {
                _fail("bad base64 in", (string)0, " an archived String or Data");
                return (Object*)0;
                }
            Object* v = (Object*)bytes;
            if (cls.isString("String"))
                v = (Object*)bytes.stringValue();
            _made.set(idx, v);
            return v;
            }
        if (cls.isString("Number"))
            {
            _JSONNode* d = node.field("$double", false);
            if (d == 0)
                {
                _fail("an archived Number has no value", (string)0, "");
                return (Object*)0;
                }
            Object* v = (Object*)Number.withDouble(_doubleOf(d, "$double"));
            _made.set(idx, v);
            return v;
            }
        if (cls.isString("Array"))
            {
            Array* a = new Array();
            _made.set(idx, a);
            _JSONNode* items = node.field("$items", false);
            if (!_checkRefs(items))
                return a;
            u32 n = items.items.count();
            for (u32 i = (u32)0; i < n; i++)
                a.add(_object(Coder._indexOf((_JSONNode*)items.items.get(i))));
            return a;
            }
        if (cls.isString("Set"))
            {
            Set* s = new Set();
            _made.set(idx, s);
            _JSONNode* items = node.field("$items", false);
            if (!_checkRefs(items))
                return s;
            u32 n = items.items.count();
            for (u32 i = (u32)0; i < n; i++)
                {
                Object* e = _object(Coder._indexOf((_JSONNode*)items.items.get(i)));
                if (e != 0)
                    s.add((Hashable*)e);
                }
            return s;
            }
        if (cls.isString("Map"))
            {
            Map* m = new Map();
            _made.set(idx, m);
            _JSONNode* keys = node.field("$keys", false);
            _JSONNode* vals = node.field("$values", false);
            if (!_checkRefs(keys) || !_checkRefs(vals))
                return m;
            u32 n = keys.items.count();
            if (vals.items.count() != n)
                {
                _fail("an archived Map has unequal key and value counts", (string)0, "");
                return m;
                }
            for (u32 i = (u32)0; i < n; i++)
                {
                Object* k = _object(Coder._indexOf((_JSONNode*)keys.items.get(i)));
                Object* v = _object(Coder._indexOf((_JSONNode*)vals.items.get(i)));
                if (k != 0)
                    m.set((Hashable*)k, v);
                }
            return m;
            }
        Object* obj = _coder_newInstance(cls.text);
        if (obj == 0)
            {
            _fail("unknown class", cls.text.cString(), "");
            return (Object*)0;
            }
        // Registered BEFORE initWithCoder, so a reference back to this object
        // from inside its own graph finds it.
        _made.set(idx, obj);
        _JSONNode* saved = _rec;
        _rec = node;
        obj.initWithCoder(self);
        _rec = saved;
        return obj;
        }

    bool _checkRefs(_JSONNode* list)
        {
        if (list == 0 || list.kind != JK_ARRAY)
            {
            _fail("an archived collection has no item list", (string)0, "");
            return false;
            }
        u32 n = list.items.count();
        for (u32 i = (u32)0; i < n; i++)
            {
            _JSONNode* r = (_JSONNode*)list.items.get(i);
            if (!r.isInteger())
                {
                _fail("an archived collection has a bad reference", (string)0, "");
                return false;
                }
            }
        return true;
        }



    // ── Keyed decoding (from inside initWithCoder) ───────────────────────
    _JSONNode* _lookup(string key)
        {
        if (!_decoding || _rec == 0)
            return (_JSONNode*)0;
        return _rec.field(key, key[0] == (u8)'$');
        }

    bool containsKey(string key)
        {
        return _lookup(key) != 0;
        }

    Object* decodeObject(string key)
        {
        _JSONNode* v = _lookup(key);
        if (v == 0)
            return (Object*)0;
        if (v.kind != JK_OBJECT)
            {
            _fail("value for key", key, " is not an object reference");
            return (Object*)0;
            }
        u32 idx = _refIndex(v, key);
        if (_error != 0)
            return (Object*)0;
        return _object(idx);
        }

    bool decodeBool(string key)
        {
        _JSONNode* v = _lookup(key);
        if (v == 0)
            return false;
        if (v.kind == JK_TRUE)
            return true;
        if (v.kind != JK_FALSE)
            _fail("value for key", key, " is not a bool");
        return false;
        }

    // A signed value in [lo, hi].
    i64 _signed(string key, i64 lo, i64 hi)
        {
        _JSONNode* v = _lookup(key);
        if (v == 0)
            return (i64)0;
        if (v.kind != JK_NUMBER)
            {
            _fail("value for key", key, " is not a number");
            return (i64)0;
            }
        i64 r = (i64)0;
        if (v.isInteger())
            {
            bool neg = false;
            bool over = false;
            u64 mag = JSON._magnitude(v.text, &neg, &over);
            if (over || (!neg && mag > (u64)0x7FFFFFFFFFFFFFFF) || (neg && mag > (u64)0x8000000000000000))
                {
                _fail("value for key", key, " is out of range");
                return (i64)0;
                }
            r = neg ? (i64)((u64)0 - mag) : (i64)mag;
            }
        else
            {
            double d = _json_parseDouble(v.text.cString(), v.text.byteLength());
            if (!(d >= -9223372036854775808.0d && d < 9223372036854775808.0d))
                {
                _fail("value for key", key, " is out of range");
                return (i64)0;
                }
            r = (i64)d;
            }
        if (r < lo || r > hi)
            {
            _fail("value for key", key, " is out of range");
            return (i64)0;
            }
        return r;
        }

    i32 decodeI32(string key)
        {
        return (i32)_signed(key, (i64)-2147483648, (i64)2147483647);
        }

    u32 decodeU32(string key)
        {
        return (u32)_signed(key, (i64)0, (i64)4294967295);
        }

    i64 decodeI64(string key)
        {
        return _signed(key, (i64)0x8000000000000000, (i64)0x7FFFFFFFFFFFFFFF);
        }

    u64 decodeU64(string key)
        {
        _JSONNode* v = _lookup(key);
        if (v == 0)
            return (u64)0;
        if (v.kind != JK_NUMBER)
            {
            _fail("value for key", key, " is not a number");
            return (u64)0;
            }
        if (v.isInteger())
            {
            bool neg = false;
            bool over = false;
            u64 mag = JSON._magnitude(v.text, &neg, &over);
            if (over || (neg && mag != (u64)0))
                {
                _fail("value for key", key, " is out of range");
                return (u64)0;
                }
            return mag;
            }
        double d = _json_parseDouble(v.text.cString(), v.text.byteLength());
        if (!(d >= 0.0d && d < 18446744073709551616.0d))
            {
            _fail("value for key", key, " is out of range");
            return (u64)0;
            }
        return (u64)d;
        }

    float decodeFloat(string key)
        {
        return (float)decodeDouble(key);
        }

    double decodeDouble(string key)
        {
        _JSONNode* v = _lookup(key);
        if (v == 0)
            return 0.0d;
        return _doubleOf(v, key);
        }

    double _doubleOf(_JSONNode* v, string key)
        {
        if (v.kind == JK_NUMBER)
            return _json_parseDouble(v.text.cString(), v.text.byteLength());
        if (v.isString("NaN"))
            return _json_dfrom((u64)0x7FF8000000000000);
        if (v.isString("Infinity"))
            return _json_dfrom((u64)0x7FF0000000000000);
        if (v.isString("-Infinity"))
            return _json_dfrom((u64)0xFFF0000000000000);
        _fail("value for key", key, " is not a number");
        return 0.0d;
        }

    // ═════════════════════════════════════════════════════════════════════
    // Base64 (RFC 4648, with padding)
    // ═════════════════════════════════════════════════════════════════════

    static void _appendBase64(String* s, u8* p, u32 n)
        {
        u8* t = _coder_b64;
        u32 i = (u32)0;
        while (i + (u32)3 <= n)
            {
            u32 v = ((u32)p[i] << (u32)16) | ((u32)p[i + (u32)1] << (u32)8) | (u32)p[i + (u32)2];
            s.appendByte(t[(v >> (u32)18) & (u32)63]);
            s.appendByte(t[(v >> (u32)12) & (u32)63]);
            s.appendByte(t[(v >> (u32)6) & (u32)63]);
            s.appendByte(t[v & (u32)63]);
            i = i + (u32)3;
            }
        u32 rest = n - i;
        if (rest == (u32)1)
            {
            u32 v = (u32)p[i] << (u32)16;
            s.appendByte(t[(v >> (u32)18) & (u32)63]);
            s.appendByte(t[(v >> (u32)12) & (u32)63]);
            s.appendCString("==");
            }
        else if (rest == (u32)2)
            {
            u32 v = ((u32)p[i] << (u32)16) | ((u32)p[i + (u32)1] << (u32)8);
            s.appendByte(t[(v >> (u32)18) & (u32)63]);
            s.appendByte(t[(v >> (u32)12) & (u32)63]);
            s.appendByte(t[(v >> (u32)6) & (u32)63]);
            s.appendByte((u8)'=');
            }
        }

    static u32 _b64Value(u8 c)
        {
        if (c >= (u8)'A' && c <= (u8)'Z')
            return (u32)(c - (u8)'A');
        if (c >= (u8)'a' && c <= (u8)'z')
            return (u32)(c - (u8)'a') + (u32)26;
        if (c >= (u8)'0' && c <= (u8)'9')
            return (u32)(c - (u8)'0') + (u32)52;
        if (c == (u8)'+')
            return (u32)62;
        if (c == (u8)'/')
            return (u32)63;
        return (u32)0xFF;
        }

    // Null when the text is not base64.
    static Data* _decodeBase64(String* text)
        {
        if (text == 0)
            return (Data*)0;
        u8* p = text.cString();
        u32 n = text.byteLength();
        if ((n & (u32)3) != (u32)0)
            return (Data*)0;
        Data* out = Data.withCapacity((n / (u32)4) * (u32)3);
        u32 i = (u32)0;
        while (i < n)
            {
            u32 pad = (u32)0;
            u32 v = (u32)0;
            for (u32 k = (u32)0; k < (u32)4; k++)
                {
                u8 c = p[i + k];
                u32 d = (u32)0;
                if (c == (u8)'=' && i + (u32)4 == n && k >= (u32)2)
                    {
                    pad = pad + (u32)1;
                    }
                else
                    {
                    if (pad != (u32)0)
                        return (Data*)0;
                    d = Coder._b64Value(c);
                    if (d == (u32)0xFF)
                        return (Data*)0;
                    }
                v = (v << (u32)6) | d;
                }
            out.appendByte((u8)(v >> (u32)16));
            if (pad < (u32)2)
                out.appendByte((u8)(v >> (u32)8));
            if (pad < (u32)1)
                out.appendByte((u8)v);
            i = i + (u32)4;
            }
        return out;
        }

    // ═════════════════════════════════════════════════════════════════════
    // gzip (RFC 1952)
    // ═════════════════════════════════════════════════════════════════════

    static u32 crc32(u8* p, u32 n)
        {
        if (_crcTable == (u32*)0)
            {
            u32* t = new u32[256];
            for (u32 i = (u32)0; i < (u32)256; i++)
                {
                u32 c = i;
                for (u32 k = (u32)0; k < (u32)8; k++)
                    {
                    if ((c & (u32)1) != (u32)0)
                        c = (u32)0xEDB88320 ^ (c >> (u32)1);
                    else
                        c = c >> (u32)1;
                    }
                t[i] = c;
                }
            _crcTable = t;
            }
        u32* tbl = _crcTable;
        u32 crc = (u32)0xFFFFFFFF;
        for (u32 i = (u32)0; i < n; i++)
            crc = tbl[(crc ^ (u32)p[i]) & (u32)$FF] ^ (crc >> (u32)8);
        return crc ^ (u32)0xFFFFFFFF;
        }

    // `data` gzipped at `level` (1 fastest, 9 smallest; 0 stores it
    // uncompressed inside the gzip wrapper).
    static Data* gzip(Data* data, u8 level)
        {
        if (data == 0)
            return Coder._gzipBytes((u8*)0, (u32)0, level);
        return Coder._gzipBytes(data.bytes(), data.length(), level);
        }

    static void _appendLE32(Data* d, u32 v)
        {
        d.appendByte((u8)(v & (u32)$FF));
        d.appendByte((u8)((v >> (u32)8) & (u32)$FF));
        d.appendByte((u8)((v >> (u32)16) & (u32)$FF));
        d.appendByte((u8)(v >> (u32)24));
        }

    static Data* _gzipBytes(u8* p, u32 n, u8 level)
        {
        Data* out = Data.withCapacity(n / (u32)3 + (u32)64);
        out.appendByte((u8)$1F);
        out.appendByte((u8)$8B);
        out.appendByte((u8)8);        // deflate
        out.appendByte((u8)0);        // no flags
        Coder._appendLE32(out, (u32)0); // no modification time
        u8 xfl = (u8)0;
        if (level == (u8)9)
            xfl = (u8)2;
        else if (level == (u8)1)
            xfl = (u8)4;
        out.appendByte(xfl);
        out.appendByte((u8)255);      // operating system unknown
        CoderDeflate.deflate(p, n, (level > (u8)9) ? (u8)9 : level, out);
        Coder._appendLE32(out, Coder.crc32(p, n));
        Coder._appendLE32(out, n);
        return out;
        }

    static u32 _le32(u8* p)
        {
        return (u32)p[0] | ((u32)p[1] << (u32)8) | ((u32)p[2] << (u32)16) | ((u32)p[3] << (u32)24);
        }

    // The contents of the first member of a gzip stream.
    static Data* gunzip(Data* data) throws
        {
        if (data == 0)
            throw new CoderError(String.withCString("gzip: no data"));
        u8* p = data.bytes();
        u32 n = data.length();
        if (n < (u32)18 || p[0] != (u8)$1F || p[1] != (u8)$8B)
            throw new CoderError(String.withCString("gzip: not gzip data"));
        if (p[2] != (u8)8)
            throw new CoderError(String.withCString("gzip: unknown compression method"));
        u8 flg = p[3];
        u32 pos = (u32)10;
        if ((flg & (u8)4) != (u8)0)
            {
            if (pos + (u32)2 > n)
                throw new CoderError(String.withCString("gzip: data ends early"));
            pos = pos + (u32)2 + ((u32)p[pos] | ((u32)p[pos + (u32)1] << (u32)8));
            }
        if ((flg & (u8)8) != (u8)0)
            {
            while (pos < n && p[pos] != (u8)0)
                pos = pos + (u32)1;
            pos = pos + (u32)1;
            }
        if ((flg & (u8)16) != (u8)0)
            {
            while (pos < n && p[pos] != (u8)0)
                pos = pos + (u32)1;
            pos = pos + (u32)1;
            }
        if ((flg & (u8)2) != (u8)0)
            pos = pos + (u32)2;
        if (pos >= n)
            throw new CoderError(String.withCString("gzip: data ends early"));
        CoderInflate* inf = new CoderInflate();
        u32 used = inf.run(&p[pos], n - pos);
        if (inf._error != (string)0)
            {
            String* msg = String.withCString("gzip: ");
            msg.appendCString(inf._error);
            throw new CoderError(msg);
            }
        pos = pos + used;
        if (pos + (u32)8 > n)
            throw new CoderError(String.withCString("gzip: data ends early"));
        u32 crc = Coder._le32(&p[pos]);
        u32 size = Coder._le32(&p[pos + (u32)4]);
        if (crc != Coder.crc32(inf._out, inf._len))
            throw new CoderError(String.withCString("gzip: CRC mismatch"));
        if (size != inf._len)
            throw new CoderError(String.withCString("gzip: length mismatch"));
        return Data.withBytes(inf._out, inf._len);
        }
    }
