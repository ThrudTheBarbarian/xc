// UXPng.xc — a PNG decoder, in xc, with nothing behind it.
//
// The seam is finished and the map still cannot be drawn, because drawing it needs the
// atlas and the atlas is a 2664x2664 PNG.  This is the decoder: inflate, the chunk
// grammar, the five scanline filters, and the colour types a UI actually meets.
//
// WHY IT IS HERE AND NOT IN A DRIVER.  Bytes to pixels is arithmetic, and arithmetic is
// the part that can be tested anywhere — so it is neutral, it is the same code on every
// backend, and it is the same code on the build box.  A backend that already has a
// decoder (Cocoa has one, and it is four lines) is welcome to use it, but the toolkit
// does not REQUIRE one, which is what makes a PNG loadable on GEM.
//
// WHAT IT SUPPORTS, and the line is drawn deliberately: 8- and 16-bit samples,
// non-interlaced, colour types 0/2/3/4/6 (grey, RGB, palette, grey+alpha, RGBA), with
// tRNS.  Adam7 interlace is REJECTED with a null return rather than mis-decoded, because
// it is cheap to add later and a decoder that half-works is worse than one that says no.
//
// 16-BIT SAMPLES ARE TAKEN TO EIGHT BY THEIR HIGH BYTE.  A 16-bit sample is v in 0..65535
// and eight bits of it is v >> 8; the alternative, round(v / 257), differs from it by at
// most one level and on the sheet the game ships it differs on 5,291 of 28,387,584 bytes
// -- which is the measurement, against a reference 8-bit export of the real atlas, not a
// preference.  The atlas is 16-bit RGBA non-interlaced, which is why this exists.
//
// The inflate is the classic two-table canonical Huffman decode (the shape of Mark
// Adler's puff, which is the shortest correct statement of it), with the three block
// types: stored, fixed and dynamic.
#import "UXImage.xc"

#define PNG_MAXBITS 15
#define PNG_MAXSYMS 288
// The literal and distance lengths are decoded into ONE array, so it is sized for the
// worst case of both: 286 literal symbols plus 30 distance ones.  Sized at 288 this
// overflowed by 28 bytes on a dynamic block, which is a heap smash and not a wrong pixel.
#define PNG_MAXLENS 320

// ---- CRC32 and Adler32 ------------------------------------------------------
u32* gCrcTable = (u32*)0;

void crcBuild(void)
    {
    if (gCrcTable != (u32*)0)
        {
        return;
        }
    gCrcTable = new u32[256];
    for (i32 n = (i32)0; n < (i32)256; n = n + (i32)1)
        {
        u32 c = (u32)n;
        for (i32 k = (i32)0; k < (i32)8; k = k + (i32)1)
            {
            if ((c & (u32)1) != (u32)0)
                {
                c = (u32)0xEDB88320 ^ (c >> (u32)1);
                }
            else
                {
                c = c >> (u32)1;
                }
            }
        gCrcTable[n] = c;
        }
    }

u32 pngCrc32(u8* data, i32 len)
    {
    crcBuild();
    u32 c = (u32)0xFFFFFFFF;
    for (i32 i = (i32)0; i < len; i = i + (i32)1)
        {
        c = gCrcTable[(c ^ (u32)data[i]) & (u32)0xFF] ^ (c >> (u32)8);
        }
    return c ^ (u32)0xFFFFFFFF;
    }

// ---- inflate ----------------------------------------------------------------
// One instance per stream, so two decodes never share a state and the decoder can be
// called from anywhere without a lock.
class UXInflate
    {
    u8* src;
    i32 inLen;
    i32 inPos;
    u32 bitBuf;
    i32 bitCnt;
    u8* out;
    i32 outLen;
    i32 outCap;
    bool err;

    // The decode tables.  `lens` is per symbol; the other four are the canonical code.
    i32* counts;
    i32* offs;
    i32* syms;

    void init(void)
        {
        src = (u8*)0;
        inLen = (i32)0;
        inPos = (i32)0;
        bitBuf = (u32)0;
        bitCnt = (i32)0;
        out = (u8*)0;
        outLen = (i32)0;
        outCap = (i32)0;
        err = false;
        counts = new i32[PNG_MAXBITS + 1];
        offs = new i32[PNG_MAXBITS + 2];
        syms = new i32[PNG_MAXSYMS];
        }

    bool failed(void)
        {
        return err;
        }
    i32 length(void)
        {
        return outLen;
        }
    u8* bytes(void)
        {
        return out;
        }

    void put(u8 b)
        {
        if (outLen >= outCap)
            {
            i32 n = outCap * (i32)2;
            if (n < (i32)65536)
                {
                n = (i32)65536;
                }
            u8* p = new u8[(u32)n];
            for (i32 i = (i32)0; i < outLen; i = i + (i32)1)
                {
                p[i] = out[i];
                }
            out = p;
            outCap = n;
            }
        out[outLen] = b;
        outLen = outLen + (i32)1;
        }

    // Bit input.  Bits arrive least-significant first inside each byte, which is the
    // opposite of how they are written on paper and the reason every inflate bug looks
    // like garbage rather than a crash.
    bool fill(i32 n)
        {
        while (bitCnt < n && inPos < inLen)
            {
            bitBuf = bitBuf | (((u32)src[inPos]) << bitCnt);
            inPos = inPos + (i32)1;
            bitCnt = bitCnt + (i32)8;
            }
        return bitCnt >= n;
        }
    u32 take(i32 n)
        {
        if (n == (i32)0)
            {
            return (u32)0;
            }
        if (!self.fill(n))
            {
            err = true;
            return (u32)0;
            }
        u32 v = bitBuf & ((((u32)1) << n) - (u32)1);
        bitBuf = bitBuf >> n;
        bitCnt = bitCnt - n;
        return v;
        }
    void align(void)
        {
        i32 drop = bitCnt % (i32)8;
        bitBuf = bitBuf >> drop;
        bitCnt = bitCnt - drop;
        }

    // Canonical Huffman: count the lengths, check the code is not over-subscribed, lay the
    // symbols out by length, and decode one bit at a time through the counts.  A single
    // symbol with a one-bit code is legal and is the one incomplete code allowed.
    bool build(u8* lens, i32 n)
        {
        for (i32 i = (i32)0; i <= PNG_MAXBITS; i = i + (i32)1)
            {
            counts[i] = (i32)0;
            }
        i32 used = (i32)0;
        for (i32 s = (i32)0; s < n; s = s + (i32)1)
            {
            if (lens[s] > (u8)PNG_MAXBITS)
                {
                err = true;
                return false;
                }
            counts[lens[s]] = counts[lens[s]] + (i32)1;
            if (lens[s] != (u8)0)
                {
                used = used + (i32)1;
                }
            }
        counts[0] = (i32)0;
        i32 left = (i32)1;
        for (i32 len = (i32)1; len <= PNG_MAXBITS; len = len + (i32)1)
            {
            left = left * (i32)2 - counts[len];
            if (left < (i32)0)
                {
                err = true;
                return false; // over-subscribed
                }
            }
        if (left > (i32)0 && used != (i32)1)
            {
            err = true;
            return false; // incomplete, and not the single-symbol case
            }
        offs[0] = (i32)0;
        offs[1] = (i32)0;
        for (i32 len = (i32)1; len < PNG_MAXBITS; len = len + (i32)1)
            {
            offs[len + 1] = offs[len] + counts[len];
            }
        for (i32 s = (i32)0; s < n; s = s + (i32)1)
            {
            if (lens[s] != (u8)0)
                {
                syms[offs[lens[s]]] = s;
                offs[lens[s]] = offs[lens[s]] + (i32)1;
                }
            }
        return true;
        }

    i32 decodeSym(void)
        {
        i32 code = (i32)0;
        i32 first = (i32)0;
        i32 index = (i32)0;
        for (i32 len = (i32)1; len <= PNG_MAXBITS; len = len + (i32)1)
            {
            code = code | (i32)self.take((i32)1);
            i32 count = counts[len];
            if (code - count < first)
                {
                return syms[index + (code - first)];
                }
            index = index + count;
            first = first + count;
            first = first * (i32)2;
            code = code * (i32)2;
            }
        err = true;
        return (i32)-1;
        }

    // The two code-length alphabets, shared by the fixed and dynamic blocks.
    bool fixedTables(void)
        {
        u8* l = new u8[PNG_MAXSYMS];
        for (i32 i = (i32)0; i < (i32)144; i = i + (i32)1)
            {
            l[i] = (u8)8;
            }
        for (i32 i = (i32)144; i < (i32)256; i = i + (i32)1)
            {
            l[i] = (u8)9;
            }
        for (i32 i = (i32)256; i < (i32)280; i = i + (i32)1)
            {
            l[i] = (u8)7;
            }
        for (i32 i = (i32)280; i < (i32)288; i = i + (i32)1)
            {
            l[i] = (u8)8;
            }
        if (!self.build(l, (i32)288))
            {
            return false;
            }
        if (!self.saveLit((i32)288))
            {
            return false;
            }
        // The fixed distance code is 32 codes of 5 bits, per RFC 1951 -- all thirty-two,
        // including the two the symbol table leaves unused.  Building only thirty makes
        // the code incomplete, and an incomplete code is refused.
        u8* d = new u8[32];
        for (i32 i = (i32)0; i < (i32)32; i = i + (i32)1)
            {
            d[i] = (u8)5;
            }
        return self.buildDist(d, (i32)32);
        }

    // The literal table has to survive while the distance table is built in the same
    // slots, so it is copied out.  Two tables, one set of arrays: no allocation churn.
    i32 litCounts[16];
    i32 litOffs[17];
    i32 litSyms[PNG_MAXSYMS];

    bool saveLit(i32 n)
        {
        for (i32 i = (i32)0; i <= PNG_MAXBITS; i = i + (i32)1)
            {
            litCounts[i] = counts[i];
            }
        for (i32 i = (i32)0; i <= PNG_MAXBITS; i = i + (i32)1)
            {
            litOffs[i] = offs[i];
            }
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            litSyms[i] = syms[i];
            }
        return true;
        }

    i32 distCounts[16];
    i32 distOffs[17];
    i32 distSyms[32];

    bool buildDist(u8* lens, i32 n)
        {
        for (i32 i = (i32)0; i <= PNG_MAXBITS; i = i + (i32)1)
            {
            distCounts[i] = (i32)0;
            }
        i32 used = (i32)0;
        for (i32 s = (i32)0; s < n; s = s + (i32)1)
            {
            if (lens[s] > (u8)PNG_MAXBITS)
                {
                err = true;
                return false;
                }
            distCounts[lens[s]] = distCounts[lens[s]] + (i32)1;
            if (lens[s] != (u8)0)
                {
                used = used + (i32)1;
                }
            }
        distCounts[0] = (i32)0;
        i32 left = (i32)1;
        for (i32 len = (i32)1; len <= PNG_MAXBITS; len = len + (i32)1)
            {
            left = left * (i32)2 - distCounts[len];
            if (left < (i32)0)
                {
                err = true;
                return false;
                }
            }
        if (left > (i32)0 && used != (i32)1)
            {
            err = true;
            return false;
            }
        distOffs[0] = (i32)0;
        distOffs[1] = (i32)0;
        for (i32 len = (i32)1; len < PNG_MAXBITS; len = len + (i32)1)
            {
            distOffs[len + 1] = distOffs[len] + distCounts[len];
            }
        for (i32 s = (i32)0; s < n; s = s + (i32)1)
            {
            if (lens[s] != (u8)0)
                {
                distSyms[distOffs[lens[s]]] = s;
                distOffs[lens[s]] = distOffs[lens[s]] + (i32)1;
                }
            }
        return true;
        }

    i32 decodeLit(void)
        {
        i32 code = (i32)0;
        i32 first = (i32)0;
        i32 index = (i32)0;
        for (i32 len = (i32)1; len <= PNG_MAXBITS; len = len + (i32)1)
            {
            code = code | (i32)self.take((i32)1);
            i32 count = litCounts[len];
            if (code - count < first)
                {
                return litSyms[index + (code - first)];
                }
            index = index + count;
            first = first + count;
            first = first * (i32)2;
            code = code * (i32)2;
            }
        err = true;
        return (i32)-1;
        }

    i32 decodeDist(void)
        {
        i32 code = (i32)0;
        i32 first = (i32)0;
        i32 index = (i32)0;
        for (i32 len = (i32)1; len <= PNG_MAXBITS; len = len + (i32)1)
            {
            code = code | (i32)self.take((i32)1);
            i32 count = distCounts[len];
            if (code - count < first)
                {
                return distSyms[index + (code - first)];
                }
            index = index + count;
            first = first + count;
            first = first * (i32)2;
            code = code * (i32)2;
            }
        err = true;
        return (i32)-1;
        }

    // The length and distance tables, straight from RFC 1951.  The last length code is
    // 258 with no extra bits, which is why its extra-bits entry is the odd one out.
    i32 lenBase(i32 sym)
        {
        i32 b[29];
        i32 e[29];
        b[0]=(i32)3; b[1]=(i32)4; b[2]=(i32)5; b[3]=(i32)6; b[4]=(i32)7; b[5]=(i32)8; b[6]=(i32)9;
        b[7]=(i32)10; b[8]=(i32)11; b[9]=(i32)13; b[10]=(i32)15; b[11]=(i32)17; b[12]=(i32)19;
        b[13]=(i32)23; b[14]=(i32)27; b[15]=(i32)31; b[16]=(i32)35; b[17]=(i32)43; b[18]=(i32)51;
        b[19]=(i32)59; b[20]=(i32)67; b[21]=(i32)83; b[22]=(i32)99; b[23]=(i32)115; b[24]=(i32)131;
        b[25]=(i32)163; b[26]=(i32)195; b[27]=(i32)227; b[28]=(i32)258;
        e[0]=(i32)0; e[1]=(i32)0; e[2]=(i32)0; e[3]=(i32)0; e[4]=(i32)0; e[5]=(i32)0; e[6]=(i32)0;
        e[7]=(i32)0; e[8]=(i32)1; e[9]=(i32)1; e[10]=(i32)1; e[11]=(i32)1; e[12]=(i32)2; e[13]=(i32)2;
        e[14]=(i32)2; e[15]=(i32)2; e[16]=(i32)3; e[17]=(i32)3; e[18]=(i32)3; e[19]=(i32)3; e[20]=(i32)4;
        e[21]=(i32)4; e[22]=(i32)4; e[23]=(i32)4; e[24]=(i32)5; e[25]=(i32)5; e[26]=(i32)5; e[27]=(i32)5;
        e[28]=(i32)0;
        return b[sym]; // (the extra-bits column is lengthExtra)
        }
    i32 lenExtra(i32 sym)
        {
        i32 e[29];
        e[0]=(i32)0; e[1]=(i32)0; e[2]=(i32)0; e[3]=(i32)0; e[4]=(i32)0; e[5]=(i32)0; e[6]=(i32)0;
        e[7]=(i32)0; e[8]=(i32)1; e[9]=(i32)1; e[10]=(i32)1; e[11]=(i32)1; e[12]=(i32)2; e[13]=(i32)2;
        e[14]=(i32)2; e[15]=(i32)2; e[16]=(i32)3; e[17]=(i32)3; e[18]=(i32)3; e[19]=(i32)3; e[20]=(i32)4;
        e[21]=(i32)4; e[22]=(i32)4; e[23]=(i32)4; e[24]=(i32)5; e[25]=(i32)5; e[26]=(i32)5; e[27]=(i32)5;
        e[28]=(i32)0;
        return e[sym];
        }
    i32 dstBase(i32 sym)
        {
        i32 b[30];
        b[0]=(i32)1; b[1]=(i32)2; b[2]=(i32)3; b[3]=(i32)4; b[4]=(i32)5; b[5]=(i32)7; b[6]=(i32)9;
        b[7]=(i32)13; b[8]=(i32)17; b[9]=(i32)25; b[10]=(i32)33; b[11]=(i32)49; b[12]=(i32)65;
        b[13]=(i32)97; b[14]=(i32)129; b[15]=(i32)193; b[16]=(i32)257; b[17]=(i32)385; b[18]=(i32)513;
        b[19]=(i32)769; b[20]=(i32)1025; b[21]=(i32)1537; b[22]=(i32)2049; b[23]=(i32)3073;
        b[24]=(i32)4097; b[25]=(i32)6145; b[26]=(i32)8193; b[27]=(i32)12289; b[28]=(i32)16385;
        b[29]=(i32)24577;
        return b[sym];
        }
    i32 dstExtra(i32 sym)
        {
        i32 e[30];
        e[0]=(i32)0; e[1]=(i32)0; e[2]=(i32)0; e[3]=(i32)0; e[4]=(i32)1; e[5]=(i32)1; e[6]=(i32)2;
        e[7]=(i32)2; e[8]=(i32)3; e[9]=(i32)3; e[10]=(i32)4; e[11]=(i32)4; e[12]=(i32)5; e[13]=(i32)5;
        e[14]=(i32)6; e[15]=(i32)6; e[16]=(i32)7; e[17]=(i32)7; e[18]=(i32)8; e[19]=(i32)8; e[20]=(i32)9;
        e[21]=(i32)9; e[22]=(i32)10; e[23]=(i32)10; e[24]=(i32)11; e[25]=(i32)11; e[26]=(i32)12;
        e[27]=(i32)12; e[28]=(i32)13; e[29]=(i32)13;
        return e[sym];
        }

    // One compressed block: the symbols, with back-references copied a byte at a time so
    // an overlapping run (distance 1, length 258) expands correctly rather than smearing.
    bool codes(void)
        {
        for (;;)
            {
            i32 sym = self.decodeLit();
            if (err)
                {
                return false;
                }
            if (sym < (i32)256)
                {
                self.put((u8)sym);
                }
            else if (sym == (i32)256)
                {
                return true;
                }
            else
                {
                i32 li = sym - (i32)257;
                if (li < (i32)0 || li > (i32)28)
                    {
                    err = true;
                    return false;
                    }
                i32 len = self.lenBase(li) + (i32)self.take(self.lenExtra(li));
                i32 ds = self.decodeDist();
                if (err || ds < (i32)0 || ds > (i32)29)
                    {
                    err = true;
                    return false;
                    }
                i32 dist = self.dstBase(ds) + (i32)self.take(self.dstExtra(ds));
                if (dist > outLen)
                    {
                    err = true;
                    return false; // a reference before the start of the stream
                    }
                for (i32 i = (i32)0; i < len; i = i + (i32)1)
                    {
                    self.put(out[outLen - dist]);
                    }
                }
            }
        }

    bool stored(void)
        {
        self.align();
        i32 len = (i32)self.take((i32)16);
        i32 nlen = (i32)self.take((i32)16);
        if (err)
            {
            return false;
            }
        if ((len ^ nlen) != (i32)0xFFFF)
            {
            err = true;
            return false;
            }
        for (i32 i = (i32)0; i < len; i = i + (i32)1)
            {
            i32 b = (i32)self.take((i32)8);
            if (err)
                {
                return false;
                }
            self.put((u8)b);
            }
        return true;
        }

    bool dynamic(void)
        {
        i32 hlit = (i32)self.take((i32)5) + (i32)257;
        i32 hdist = (i32)self.take((i32)5) + (i32)1;
        i32 hclen = (i32)self.take((i32)4) + (i32)4;
        if (err || hlit > (i32)286 || hdist > (i32)30)
            {
            err = true;
            return false;
            }
        i32 order[19];
        order[0]=(i32)16; order[1]=(i32)17; order[2]=(i32)18; order[3]=(i32)0; order[4]=(i32)8;
        order[5]=(i32)7; order[6]=(i32)9; order[7]=(i32)6; order[8]=(i32)10; order[9]=(i32)5;
        order[10]=(i32)11; order[11]=(i32)4; order[12]=(i32)12; order[13]=(i32)3; order[14]=(i32)13;
        order[15]=(i32)2; order[16]=(i32)14; order[17]=(i32)1; order[18]=(i32)15;
        u8* clens = new u8[19];
        for (i32 i = (i32)0; i < (i32)19; i = i + (i32)1)
            {
            clens[i] = (u8)0;
            }
        for (i32 i = (i32)0; i < hclen; i = i + (i32)1)
            {
            clens[order[i]] = (u8)self.take((i32)3);
            }
        if (err || !self.build(clens, (i32)19))
            {
            return false;
            }
        // The code-length alphabet is decoded through the generic tables, so the literal
        // table has to be saved first.
        if (!self.saveLit((i32)PNG_MAXSYMS))
            {
            return false;
            }
        for (i32 i = (i32)0; i <= PNG_MAXBITS; i = i + (i32)1)
            {
            litCounts[i] = counts[i];
            }
        for (i32 i = (i32)0; i <= PNG_MAXBITS; i = i + (i32)1)
            {
            litOffs[i] = offs[i];
            }
        for (i32 i = (i32)0; i < (i32)19; i = i + (i32)1)
            {
            litSyms[i] = syms[i];
            }
        u8* lens = new u8[PNG_MAXLENS];
        for (i32 i = (i32)0; i < PNG_MAXLENS; i = i + (i32)1)
            {
            lens[i] = (u8)0;
            }
        i32 i = (i32)0;
        while (i < hlit + hdist)
            {
            i32 sym = self.decodeLit();
            if (err)
                {
                return false;
                }
            if (sym < (i32)16)
                {
                lens[i] = (u8)sym;
                i = i + (i32)1;
                }
            else if (sym == (i32)16)
                {
                if (i == (i32)0)
                    {
                    err = true;
                    return false;
                    }
                i32 prev = (i32)lens[i - (i32)1];
                i32 n = (i32)3 + (i32)self.take((i32)2);
                while (n > (i32)0 && i < hlit + hdist)
                    {
                    lens[i] = (u8)prev;
                    i = i + (i32)1;
                    n = n - (i32)1;
                    }
                }
            else if (sym == (i32)17)
                {
                i32 n = (i32)3 + (i32)self.take((i32)3);
                while (n > (i32)0 && i < hlit + hdist)
                    {
                    lens[i] = (u8)0;
                    i = i + (i32)1;
                    n = n - (i32)1;
                    }
                }
            else if (sym == (i32)18)
                {
                i32 n = (i32)11 + (i32)self.take((i32)7);
                while (n > (i32)0 && i < hlit + hdist)
                    {
                    lens[i] = (u8)0;
                    i = i + (i32)1;
                    n = n - (i32)1;
                    }
                }
            else
                {
                err = true;
                return false;
                }
            }
        if (err)
            {
            return false;
            }
        if (!self.build(lens, hlit))
            {
            return false;
            }
        if (!self.saveLit(hlit))
            {
            return false;
            }
        u8* dlens = new u8[30];
        for (i32 d = (i32)0; d < (i32)30; d = d + (i32)1)
            {
            dlens[d] = (d < hdist) ? lens[hlit + d] : (u8)0;
            }
        return self.buildDist(dlens, (i32)30);
        }

    // The stream: a zlib wrapper with a two-byte header and a four-byte Adler-32 trailer.
    bool run(u8* data, i32 len)
        {
        src = data;
        inLen = len;
        inPos = (i32)0;
        // The header is (CMF, FLG): deflate, 32K window, check the header checksum is a
        // multiple of 31 -- the one cheap test that catches a stream that is not zlib.
        if (len < (i32)6)
            {
            err = true;
            return false;
            }
        i32 cmf = (i32)data[0];
        i32 flg = (i32)data[1];
        if ((cmf & (i32)0x0F) != (i32)8)
            {
            err = true;
            return false;
            }
        if (((cmf * (i32)256) + flg) % (i32)31 != (i32)0)
            {
            err = true;
            return false;
            }
        inPos = (i32)2;
        i32 last = (i32)0;
        while (last == (i32)0 && !err)
            {
            last = (i32)self.take((i32)1);
            i32 type = (i32)self.take((i32)2);
            if (type == (i32)0)
                {
                self.stored();
                }
            else if (type == (i32)1)
                {
                if (self.fixedTables())
                    {
                    self.codes();
                    }
                }
            else if (type == (i32)2)
                {
                if (self.dynamic())
                    {
                    self.codes();
                    }
                }
            else
                {
                err = true;
                }
            }
        return !err;
        }
    }

// ---- the PNG container ------------------------------------------------------
// The colour types, as the file numbers them.
#define PNG_GREY 0
#define PNG_RGB 2
#define PNG_PAL 3
#define PNG_GA 4
#define PNG_RGBA 6

class UXPng
    {
    u8* data;
    i32 len;
    i32 pos;
    i32 width;
    i32 height;
    i32 depth;
    i32 colour;
    i32 channels;
    i32 rowBytes;
    u8* palette;   // 256*3, for type 3
    i32 palCount;
    u8* trns;      // 256, alpha per palette entry (type 3) or one grey/RGB triple
    i32 trnsLen;

    void init(void)
        {
        data = (u8*)0;
        len = (i32)0;
        pos = (i32)0;
        width = (i32)0;
        height = (i32)0;
        depth = (i32)0;
        colour = (i32)0;
        channels = (i32)0;
        rowBytes = (i32)0;
        palette = new u8[768];
        palCount = (i32)0;
        trns = new u8[256];
        trnsLen = (i32)0;
        }

    static i32 be32(u8* p)
        {
        return ((i32)p[0] << (i32)24) | ((i32)p[1] << (i32)16) | ((i32)p[2] << (i32)8) | (i32)p[3];
        }

    static i32 channelsOf(i32 ct)
        {
        if (ct == PNG_GREY)
            {
            return (i32)1;
            }
        if (ct == PNG_RGB)
            {
            return (i32)3;
            }
        if (ct == PNG_PAL)
            {
            return (i32)1;
            }
        if (ct == PNG_GA)
            {
            return (i32)2;
            }
        return (i32)4;
        }

    // Paeth, exactly as the specification states it.  Two of the three candidates sit in
    // the same relationship to the third whichever way the test is written, so it is
    // spelled out rather than clever.
    static i32 paeth(i32 a, i32 b, i32 c)
        {
        i32 p = a + b - c;
        i32 pa = p > a ? p - a : a - p;
        i32 pb = p > b ? p - b : b - p;
        i32 pc = p > c ? p - c : c - p;
        if (pa <= pb && pa <= pc)
            {
            return a;
            }
        if (pb <= pc)
            {
            return b;
            }
        return c;
        }

    bool header(void)
        {
        if (len < (i32)8)
            {
            return false;
            }
        u8 sig[8];
        sig[0]=(u8)137; sig[1]=(u8)80; sig[2]=(u8)78; sig[3]=(u8)71;
        sig[4]=(u8)13; sig[5]=(u8)10; sig[6]=(u8)26; sig[7]=(u8)10;
        for (i32 i = (i32)0; i < (i32)8; i = i + (i32)1)
            {
            if (data[i] != sig[i])
                {
                return false;
                }
            }
        pos = (i32)8;
        return true;
        }

    static bool validDepth(i32 ct, i32 d)
        {
        if (ct == PNG_GREY)
            {
            return d == (i32)1 || d == (i32)2 || d == (i32)4 || d == (i32)8 || d == (i32)16;
            }
        if (ct == PNG_PAL)
            {
            return d == (i32)1 || d == (i32)2 || d == (i32)4 || d == (i32)8;
            }
        return d == (i32)8 || d == (i32)16;
        }

    // A sample, whatever the bit depth.  Sub-byte depths are packed high-bit first with
    // no padding except at the end of the row.  At 16 bits this is the HIGH byte, which is
    // the eight bits the pixel is drawn with.
    i32 sampleAt(u8* row, i32 index)
        {
        if (depth == (i32)8)
            {
            return (i32)row[index];
            }
        if (depth == (i32)16)
            {
            return (i32)row[index * (i32)2];
            }
        i32 per = (i32)8 / depth;
        i32 byteAt = index / per;
        i32 within = index - byteAt * per;
        i32 shift = (per - within - (i32)1) * depth;
        i32 mask = ((i32)1 << depth) - (i32)1;
        return ((i32)row[byteAt] >> shift) & mask;
        }

    // The WHOLE sample, both bytes at 16 bits.  tRNS names an exact sample rather than a
    // colour, so at 16 bits the comparison has to see both bytes: two samples that share a
    // high byte are different colours, and matching only that byte would make one of them
    // transparent.
    i32 sampleFull(u8* row, i32 index)
        {
        if (depth == (i32)16)
            {
            return ((i32)row[index * (i32)2] << (i32)8) | (i32)row[index * (i32)2 + 1];
            }
        return self.sampleAt(row, index);
        }

    static i32 scaleTo8(i32 v, i32 d)
        {
        if (d == (i32)8)
            {
            return v;
            }
        if (d == (i32)16)
            {
            return v; // the high byte, already
            }
        i32 max = ((i32)1 << d) - (i32)1;
        return (v * (i32)255) / max;
        }

    // One filtered row -> RGBA pixels.  `cur` is the row as it arrived (still filtered);
    // `prev` is the row before it, already reconstructed.
    void unfilterRow(u8* cur, u8* prev, i32 n, i32 bpp)
        {
        i32 f = (i32)cur[0];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            i32 raw = (i32)cur[i + (i32)1];
            i32 left = i >= bpp ? (i32)cur[i + (i32)1 - bpp] : (i32)0;
            i32 up = prev != (u8*)0 ? (i32)prev[i + (i32)1] : (i32)0;
            i32 ul = (prev != (u8*)0 && i >= bpp) ? (i32)prev[i + (i32)1 - bpp] : (i32)0;
            i32 v = raw;
            if (f == (i32)1)
                {
                v = raw + left;
                }
            else if (f == (i32)2)
                {
                v = raw + up;
                }
            else if (f == (i32)3)
                {
                v = raw + ((left + up) / (i32)2);
                }
            else if (f == (i32)4)
                {
                v = raw + UXPng.paeth(left, up, ul);
                }
            else if (f != (i32)0)
                {
                v = raw; // an unknown filter is left alone rather than guessed at
                }
            cur[i + (i32)1] = (u8)(v & (i32)255);
            }
        }

    u32 pixelOf(u8* row, i32 x)
        {
        i32 base = x * channels;
        if (colour == PNG_RGBA)
            {
            i32 r = self.sampleAt(row, base);
            i32 g = self.sampleAt(row, base + (i32)1);
            i32 b = self.sampleAt(row, base + (i32)2);
            i32 a = self.sampleAt(row, base + (i32)3);
            return ((u32)a << (u32)24) | ((u32)r << (u32)16) | ((u32)g << (u32)8) | (u32)b;
            }
        if (colour == PNG_RGB)
            {
            i32 r = self.sampleAt(row, base);
            i32 g = self.sampleAt(row, base + (i32)1);
            i32 b = self.sampleAt(row, base + (i32)2);
            i32 a = (i32)255;
            // tRNS on a truecolour image names one exact colour that is transparent.  The
            // chunk is ALWAYS three two-byte samples, even in an 8-bit file, so the depth
            // decides which byte the value lives in.
            if (trnsLen >= (i32)6)
                {
                if (depth == (i32)16)
                    {
                    i32 tr = ((i32)trns[0] << (i32)8) | (i32)trns[1];
                    i32 tg = ((i32)trns[2] << (i32)8) | (i32)trns[3];
                    i32 tb = ((i32)trns[4] << (i32)8) | (i32)trns[5];
                    if (self.sampleFull(row, base) == tr && self.sampleFull(row, base + (i32)1) == tg
                        && self.sampleFull(row, base + (i32)2) == tb)
                        {
                        a = (i32)0;
                        }
                    }
                else if (r == (i32)trns[1] && g == (i32)trns[3] && b == (i32)trns[5])
                    {
                    a = (i32)0;
                    }
                }
            return ((u32)a << (u32)24) | ((u32)r << (u32)16) | ((u32)g << (u32)8) | (u32)b;
            }
        if (colour == PNG_GREY)
            {
            // A sub-byte grey is a sample, not a colour: 1 at one bit deep is white, so the
            // sample is stretched to eight bits here.  A palette index is left alone -- it is
            // an index, and stretching it would look up the wrong entry.
            i32 v = UXPng.scaleTo8(self.sampleAt(row, base), depth);
            i32 a = (i32)255;
            if (trnsLen >= (i32)2)
                {
                if (depth == (i32)16)
                    {
                    if (self.sampleFull(row, base) == (((i32)trns[0] << (i32)8) | (i32)trns[1]))
                        {
                        a = (i32)0;
                        }
                    }
                else if (v == (i32)trns[1])
                    {
                    a = (i32)0;
                    }
                }
            u32 g8 = (u32)v;
            return ((u32)a << (u32)24) | (g8 << (u32)16) | (g8 << (u32)8) | g8;
            }
        if (colour == PNG_GA)
            {
            i32 v = UXPng.scaleTo8(self.sampleAt(row, base), depth);
            i32 a = UXPng.scaleTo8(self.sampleAt(row, base + (i32)1), depth);
            u32 g8 = (u32)v;
            return ((u32)a << (u32)24) | (g8 << (u32)16) | (g8 << (u32)8) | g8;
            }
        // Palette: an index, then the table, then the optional per-entry alpha.
        i32 idx = self.sampleAt(row, base);
        if (idx < (i32)0 || idx >= palCount)
            {
            idx = (i32)0;
            }
        i32 r = (i32)palette[idx * (i32)3];
        i32 g = (i32)palette[idx * (i32)3 + 1];
        i32 b = (i32)palette[idx * (i32)3 + 2];
        i32 a = (i32)255;
        if (idx < trnsLen)
            {
            a = (i32)trns[idx];
            }
        return ((u32)a << (u32)24) | ((u32)r << (u32)16) | ((u32)g << (u32)8) | (u32)b;
        }

    UXImage* build(u8* raw, i32 rawLen)
        {
        i32 bpp = (channels * depth) / (i32)8;
        if (bpp < (i32)1)
            {
            bpp = (i32)1;
            }
        i32 stride = rowBytes + (i32)1; // the filter byte
        if (rawLen < stride * height)
            {
            return (UXImage*)0;
            }
        UXImage* im = UXImage.make(width, height);
        u8* prev = (u8*)0;
        for (i32 y = (i32)0; y < height; y = y + (i32)1)
            {
            // cur points at the filter byte; unfilterRow rewrites the row in place and
            // leaves that byte alone, so the pixels start one past it.
            u8* cur = raw + y * stride;
            self.unfilterRow(cur, prev, rowBytes, bpp);
            for (i32 x = (i32)0; x < width; x = x + (i32)1)
                {
                im.setPixelRaw(x, y, self.pixelOf(cur + (i32)1, x));
                }
            prev = cur;
            }
        return im;
        }

    // The chunk loop.  Every chunk carries a CRC over its type and its data, and it is
    // verified: a truncated download is the failure this decoder will actually meet, and
    // a silent half-image is worse than a null.
    u8* collect(i32* outLen)
        {
        u8* idat = (u8*)0;
        i32 idatLen = (i32)0;
        i32 idatCap = (i32)0;
        bool sawHeader = false;
        while (pos + (i32)12 <= len)
            {
            i32 clen = UXPng.be32(data + pos);
            if (clen < (i32)0 || pos + (i32)12 + clen > len)
                {
                return (u8*)0;
                }
            u8* type = data + pos + (i32)4;
            u8* body = data + pos + (i32)8;
            u32 want = (u32)UXPng.be32(data + pos + (i32)8 + clen);
            if (pngCrc32(data + pos + (i32)4, clen + (i32)4) != want)
                {
                return (u8*)0;
                }
            bool isIhdr = type[0] == (u8)'I' && type[1] == (u8)'H' && type[2] == (u8)'D' && type[3] == (u8)'R';
            bool isPlte = type[0] == (u8)'P' && type[1] == (u8)'L' && type[2] == (u8)'T' && type[3] == (u8)'E';
            bool isTrns = type[0] == (u8)'t' && type[1] == (u8)'R' && type[2] == (u8)'N' && type[3] == (u8)'S';
            bool isIdat = type[0] == (u8)'I' && type[1] == (u8)'D' && type[2] == (u8)'A' && type[3] == (u8)'T';
            bool isIend = type[0] == (u8)'I' && type[1] == (u8)'E' && type[2] == (u8)'N' && type[3] == (u8)'D';
            if (isIhdr)
                {
                if (clen < (i32)13)
                    {
                    return (u8*)0;
                    }
                width = UXPng.be32(body);
                height = UXPng.be32(body + (i32)4);
                depth = (i32)body[8];
                colour = (i32)body[9];
                i32 compression = (i32)body[10];
                i32 filter = (i32)body[11];
                i32 interlace = (i32)body[12];
                if (width <= (i32)0 || height <= (i32)0)
                    {
                    return (u8*)0;
                    }
                if (compression != (i32)0 || filter != (i32)0)
                    {
                    return (u8*)0;
                    }
                if (interlace != (i32)0)
                    {
                    return (u8*)0; // Adam7: refused loudly, not half-decoded
                    }
                if (colour != PNG_GREY && colour != PNG_RGB && colour != PNG_PAL && colour != PNG_GA && colour != PNG_RGBA)
                    {
                    return (u8*)0;
                    }
                if (!UXPng.validDepth(colour, depth))
                    {
                    return (u8*)0;
                    }
                channels = UXPng.channelsOf(colour);
                rowBytes = (width * channels * depth + (i32)7) / (i32)8;
                sawHeader = true;
                }
            else if (!sawHeader)
                {
                return (u8*)0; // IHDR is required and required first
                }
            else if (isPlte)
                {
                palCount = clen / (i32)3;
                if (palCount > (i32)256)
                    {
                    palCount = (i32)256;
                    }
                for (i32 i = (i32)0; i < palCount * (i32)3; i = i + (i32)1)
                    {
                    palette[i] = body[i];
                    }
                }
            else if (isTrns)
                {
                trnsLen = clen > (i32)256 ? (i32)256 : clen;
                for (i32 i = (i32)0; i < trnsLen; i = i + (i32)1)
                    {
                    trns[i] = body[i];
                    }
                }
            else if (isIdat)
                {
                if (idatLen + clen > idatCap)
                    {
                    i32 nc = idatCap == (i32)0 ? (i32)65536 : idatCap;
                    while (nc < idatLen + clen)
                        {
                        nc = nc * (i32)2;
                        }
                    u8* np = new u8[(u32)nc];
                    for (i32 i = (i32)0; i < idatLen; i = i + (i32)1)
                        {
                        np[i] = idat[i];
                        }
                    idat = np;
                    idatCap = nc;
                    }
                for (i32 i = (i32)0; i < clen; i = i + (i32)1)
                    {
                    idat[idatLen + i] = body[i];
                    }
                idatLen = idatLen + clen;
                }
            else if (isIend)
                {
                pos = pos + (i32)12 + clen;
                break;
                }
            // Every other chunk (gAMA, pHYs, iCCP, tEXt, ...) is skipped: it changes how a
            // colour SHOULD be displayed and not what the pixels ARE, and a decoder that
            // pretends to honour it without a colour-managed pipeline is lying.
            pos = pos + (i32)12 + clen;
            }
        if (idatLen == (i32)0)
            {
            return (u8*)0;
            }
        outLen[0] = idatLen;
        return idat;
        }

    // The only entry point an app needs.
    static UXImage* decode(u8* bytes, i32 n)
        {
        UXPng* p = new UXPng();
        p.data = bytes;
        p.len = n;
        if (!p.header())
            {
            return (UXImage*)0;
            }
        i32 idatLen = (i32)0;
        u8* idat = p.collect(&idatLen);
        if (idat == (u8*)0)
            {
            return (UXImage*)0;
            }
        UXInflate* inf = new UXInflate();
        if (!inf.run(idat, idatLen))
            {
            return (UXImage*)0;
            }
        UXImage* r = p.build(inf.bytes(), inf.length());
        return r;
        }
    }
