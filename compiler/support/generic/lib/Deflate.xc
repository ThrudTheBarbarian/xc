// Deflate.xc — RFC 1951 deflate and inflate, and the CRC-32 of RFC 1952.
//
// The compression Coder's archives use (`archive(root, level)` gzips the JSON,
// `unarchive` and `Coder.gunzip` undo it), in a file of its own so code that
// needs only these (the debug-file reader, which inflates compressed DWARF and
// checks a separate debug file's CRC) does not take the whole of Coder with
// it. Every target, xt6502 included: nothing here archives.
//
// CoderDeflate.deflate(src, n, level, out) appends the compressed bytes to
// out; a CoderInflate is given its input and run, and leaves the bytes in
// _out (_len of them) or a reason in _error; CoderCrc.crc32(p, n) is the
// CRC-32 gzip and separate debug files use.

#import "Foundation.xc"

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
// CoderCrc — the CRC-32 of RFC 1952 (gzip), and of a separate debug file's
// .gnu_debuglink.
// ═════════════════════════════════════════════════════════════════════════════

class CoderCrc
    {
    static u32* _table;

    static u32 crc32(u8* p, u32 n)
        {
        if (_table == (u32*)0)
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
            _table = t;
            }
        u32* tbl = _table;
        u32 crc = (u32)0xFFFFFFFF;
        for (u32 i = (u32)0; i < n; i++)
            crc = tbl[(crc ^ (u32)p[i]) & (u32)$FF] ^ (crc >> (u32)8);
        return crc ^ (u32)0xFFFFFFFF;
        }
    }
