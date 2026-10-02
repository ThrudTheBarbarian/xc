// UXJpeg.xc — a baseline JPEG decoder, in xc, with nothing behind it.
//
// UXPng's sibling, for the same reason: bytes to pixels is arithmetic, so it is neutral, the same
// code on every backend and on the build box, and a backend needs no decoder of its own.  The
// client's paper and water textures are JPEGs, and nothing else in the toolkit decodes one.
//
// WHAT IT SUPPORTS, and the line is drawn deliberately: baseline and extended-sequential Huffman
// (SOF0, SOF1) at 8-bit precision; greyscale and three-component YCbCr (or RGB, when an Adobe
// marker says it is untransformed); any sampling factors (4:4:4, 4:2:2, 4:2:0, ...); interleaved
// and single-component scans; restart intervals.  REFUSED with a null return rather than
// mis-decoded: progressive (SOF2), lossless, arithmetic coding, 12-bit samples, and four-component
// (CMYK) images -- a decoder that half-works is worse than one that says no.
//
// IT MATCHES LIBJPEG BYTE FOR BYTE in the configuration `djpeg -dct int -nosmooth`: the IDCT is
// libjpeg's "islow" (Loeffler-Ligtenberg-Moschytz, 13-bit constants, two passes, its range-limit
// table), the colour conversion is its fixed-point YCbCr tables, and chroma is replicated, not
// interpolated.  That is what makes the test exact rather than a tolerance: test_jpeg compares every
// byte with libjpeg's own output for the same file.
#import "UXImage.xc"

// The order coefficients arrive in, zig-zag to natural.
i32 gJpegZigzag[64] = {
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};

// libjpeg's IDCT range limit: a sample v (centred on 0) becomes clamp(v + 128), indexed by v & 1023
// so that wildly out-of-range values wrap the way libjpeg's do rather than merely clamp.
u8 gJpegRange[1024];
bool gJpegRangeBuilt;
void jpegBuildRange(void)
    {
    if (gJpegRangeBuilt)
        {
        return;
        }
    for (i32 i = (i32)0; i < (i32)1024; i = i + (i32)1)
        {
        i32 v = (i32)0;
        if (i < (i32)128)
            {
            v = i + (i32)128;
            }
        else if (i < (i32)512)
            {
            v = (i32)255;
            }
        else if (i < (i32)896)
            {
            v = (i32)0;
            }
        else
            {
            v = i - (i32)896;
            }
        gJpegRange[i] = (u8)v;
        }
    gJpegRangeBuilt = true;
    }
u8 jpegClamp(i32 v)
    {
    return (u8)(v < (i32)0 ? (i32)0 : (v > (i32)255 ? (i32)255 : v));
    }

// One Huffman table, canonical: per code length, the smallest and largest code and where its
// symbols start in vals.
class UXJpegHuff
    {
    i32 mincode[17];
    i32 maxcode[18];
    i32 valptr[17];
    u8 vals[256];
    bool defined;
    void init(void)
        {
        defined = false;
        }
    // counts[1..16] = how many codes of each length; vals in code order.
    bool build(u8* counts, u8* symbols, i32 n)
        {
        if (n > (i32)256)
            {
            return false;
            }
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            vals[i] = symbols[i];
            }
        i32 code = (i32)0;
        i32 k = (i32)0;
        for (i32 len = (i32)1; len <= (i32)16; len = len + (i32)1)
            {
            i32 c = (i32)counts[len - (i32)1];
            valptr[len] = k;
            mincode[len] = code;
            code = code + c;
            k = k + c;
            maxcode[len] = c > (i32)0 ? code - (i32)1 : (i32)-1;
            code = code << (i32)1;
            }
        maxcode[17] = (i32)0x7FFFFFFF;
        defined = true;
        return k == n;
        }
    }

class UXJpegComp
    {
    i32 id;
    i32 h;        // sampling factors
    i32 v;
    i32 tq;       // quantisation table
    i32 td;       // DC / AC Huffman tables for the current scan
    i32 ta;
    i32 pred;     // DC prediction
    i32 bw;       // the plane's size in blocks (whole MCUs' worth)
    i32 bh;
    u8* plane;    // bw*8 x bh*8 samples
    void init(void)
        {
        plane = (u8*)0;
        }
    }

class UXJpeg
    {
    u8* data;
    i32 len;
    i32 pos;
    bool bad;
    i32 width;
    i32 height;
    i32 ncomp;
    i32 hmax;
    i32 vmax;
    i32 mcusX;
    i32 mcusY;
    i32 restartInterval;
    i32 adobeTransform; // -1 = no Adobe marker
    bool frameSeen;
    u16 quant[256];     // 4 tables of 64, natural order
    // Held in Arrays, which own what they hold: an object stored ONLY in a fixed-size array field is
    // not retained, and would be freed (and its memory reused) as soon as the code that made it
    // returned.  tabs: DC tables 0-3 then AC tables 0-3.
    Array* tabs;
    Array* comps;
    // the entropy-coded bit reader
    u32 bitBuf;
    i32 bitCnt;
    bool markerHit;
    bool exhausted;     // the data ran out mid-scan: a truncated file
    i32 blk[64];

    void init(void)
        {
        data = (u8*)0;
        len = (i32)0;
        pos = (i32)0;
        bad = false;
        width = (i32)0;
        height = (i32)0;
        ncomp = (i32)0;
        restartInterval = (i32)0;
        adobeTransform = (i32)-1;
        frameSeen = false;
        tabs = new Array();
        comps = new Array();
        for (i32 i = (i32)0; i < (i32)8; i = i + (i32)1)
            {
            tabs.add(new UXJpegHuff());
            }
        for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
            {
            comps.add(new UXJpegComp());
            }
        }

    UXJpegHuff* dcTab(i32 i)
        {
        return (UXJpegHuff* ?)tabs.get((u32)i);
        }
    UXJpegHuff* acTab(i32 i)
        {
        return (UXJpegHuff* ?)tabs.get((u32)(i + (i32)4));
        }
    UXJpegComp* comp(i32 i)
        {
        return (UXJpegComp* ?)comps.get((u32)i);
        }
    i32 u16at(i32 p)
        {
        if (p + (i32)1 >= len)
            {
            bad = true;
            return (i32)0;
            }
        return ((i32)data[p] << (i32)8) | (i32)data[p + (i32)1];
        }

    // ---- bits ----------------------------------------------------------------------------------
    // A 0xFF in the entropy data is followed by 0x00 (a stuffed byte) or begins a marker; at a marker
    // the reader stops and feeds zeros, as libjpeg does, and the caller deals with the marker.
    void resetBits(void)
        {
        bitBuf = (u32)0;
        bitCnt = (i32)0;
        markerHit = false;
        exhausted = false;
        }
    i32 bit(void)
        {
        if (bitCnt == (i32)0)
            {
            i32 b = (i32)0;
            if (!markerHit && pos >= len)
                {
                exhausted = true;
                }
            if (!markerHit && pos < len)
                {
                b = (i32)data[pos];
                if (b == (i32)255)
                    {
                    i32 nx = pos + (i32)1 < len ? (i32)data[pos + (i32)1] : (i32)0;
                    if (nx == (i32)0)
                        {
                        pos = pos + (i32)2;
                        }
                    else
                        {
                        markerHit = true; // leave pos AT the marker
                        b = (i32)0;
                        }
                    }
                else
                    {
                    pos = pos + (i32)1;
                    }
                }
            bitBuf = (u32)b;
            bitCnt = (i32)8;
            }
        bitCnt = bitCnt - (i32)1;
        return (i32)((bitBuf >> (u32)bitCnt) & (u32)1);
        }
    i32 receive(i32 s)
        {
        i32 v = (i32)0;
        for (i32 i = (i32)0; i < s; i = i + (i32)1)
            {
            v = (v << (i32)1) | self.bit();
            }
        return v;
        }
    // JPEG's sign extension: an s-bit value below 2^(s-1) is negative.
    i32 extend(i32 v, i32 s)
        {
        if (s == (i32)0)
            {
            return (i32)0;
            }
        return v < ((i32)1 << (s - (i32)1)) ? v - ((i32)1 << s) + (i32)1 : v;
        }
    i32 decodeHuff(UXJpegHuff* t)
        {
        i32 code = self.bit();
        i32 l = (i32)1;
        while (code > t.maxcode[l])
            {
            code = (code << (i32)1) | self.bit();
            l = l + (i32)1;
            if (l > (i32)16)
                {
                bad = true;
                return (i32)0;
                }
            }
        return (i32)t.vals[t.valptr[l] + code - t.mincode[l]];
        }

    // ---- one block -----------------------------------------------------------------------------
    void decodeBlock(UXJpegComp* c)
        {
        for (i32 i = (i32)0; i < (i32)64; i = i + (i32)1)
            {
            blk[i] = (i32)0;
            }
        UXJpegHuff* dc = self.dcTab(c.td);
        UXJpegHuff* ac = self.acTab(c.ta);
        if (!dc.defined || !ac.defined)
            {
            bad = true;
            return;
            }
        i32 t = self.decodeHuff(dc);
        i32 diff = t > (i32)0 ? self.extend(self.receive(t), t) : (i32)0;
        c.pred = c.pred + diff;
        u16* q = &quant[c.tq * (i32)64];
        blk[0] = c.pred * (i32)q[0];
        i32 k = (i32)1;
        while (k < (i32)64)
            {
            i32 rs = self.decodeHuff(ac);
            i32 r = rs >> (i32)4;
            i32 s = rs & (i32)15;
            if (s != (i32)0)
                {
                k = k + r;
                if (k > (i32)63)
                    {
                    bad = true;
                    return;
                    }
                i32 z = gJpegZigzag[k];
                blk[z] = self.extend(self.receive(s), s) * (i32)q[z];
                k = k + (i32)1;
                }
            else if (r == (i32)15)
                {
                k = k + (i32)16;
                }
            else
                {
                k = (i32)64;
                }
            }
        }

    // libjpeg's jpeg_idct_islow, on the dequantised block, into 8x8 samples of the plane.
    void idct(UXJpegComp* c, i32 bx, i32 by)
        {
        i64 ws[64];
        for (i32 col = (i32)0; col < (i32)8; col = col + (i32)1)
            {
            i64 i0 = (i64)blk[col];
            i64 i1 = (i64)blk[col + (i32)8];
            i64 i2 = (i64)blk[col + (i32)16];
            i64 i3 = (i64)blk[col + (i32)24];
            i64 i4 = (i64)blk[col + (i32)32];
            i64 i5 = (i64)blk[col + (i32)40];
            i64 i6 = (i64)blk[col + (i32)48];
            i64 i7 = (i64)blk[col + (i32)56];
            if (i1 == (i64)0 && i2 == (i64)0 && i3 == (i64)0 && i4 == (i64)0 && i5 == (i64)0 && i6 == (i64)0 && i7 == (i64)0)
                {
                i64 dcv = i0 << (i64)2; // PASS1_BITS
                for (i32 r = (i32)0; r < (i32)8; r = r + (i32)1)
                    {
                    ws[col + r * (i32)8] = dcv;
                    }
                continue;
                }
            i64 z1 = (i2 + i6) * (i64)4433;
            i64 tmp2 = z1 + i6 * (i64)-15137;
            i64 tmp3 = z1 + i2 * (i64)6270;
            i64 tmp0 = (i0 + i4) << (i64)13;
            i64 tmp1 = (i0 - i4) << (i64)13;
            i64 tmp10 = tmp0 + tmp3;
            i64 tmp13 = tmp0 - tmp3;
            i64 tmp11 = tmp1 + tmp2;
            i64 tmp12 = tmp1 - tmp2;
            tmp0 = i7;
            tmp1 = i5;
            tmp2 = i3;
            tmp3 = i1;
            z1 = tmp0 + tmp3;
            i64 z2 = tmp1 + tmp2;
            i64 z3 = tmp0 + tmp2;
            i64 z4 = tmp1 + tmp3;
            i64 z5 = (z3 + z4) * (i64)9633;
            tmp0 = tmp0 * (i64)2446;
            tmp1 = tmp1 * (i64)16819;
            tmp2 = tmp2 * (i64)25172;
            tmp3 = tmp3 * (i64)12299;
            z1 = z1 * (i64)-7373;
            z2 = z2 * (i64)-20995;
            z3 = z3 * (i64)-16069;
            z4 = z4 * (i64)-3196;
            z3 = z3 + z5;
            z4 = z4 + z5;
            tmp0 = tmp0 + z1 + z3;
            tmp1 = tmp1 + z2 + z4;
            tmp2 = tmp2 + z2 + z3;
            tmp3 = tmp3 + z1 + z4;
            // DESCALE by CONST_BITS - PASS1_BITS = 11
            ws[col] = (tmp10 + tmp3 + (i64)1024) >> (i64)11;
            ws[col + (i32)56] = (tmp10 - tmp3 + (i64)1024) >> (i64)11;
            ws[col + (i32)8] = (tmp11 + tmp2 + (i64)1024) >> (i64)11;
            ws[col + (i32)48] = (tmp11 - tmp2 + (i64)1024) >> (i64)11;
            ws[col + (i32)16] = (tmp12 + tmp1 + (i64)1024) >> (i64)11;
            ws[col + (i32)40] = (tmp12 - tmp1 + (i64)1024) >> (i64)11;
            ws[col + (i32)24] = (tmp13 + tmp0 + (i64)1024) >> (i64)11;
            ws[col + (i32)32] = (tmp13 - tmp0 + (i64)1024) >> (i64)11;
            }
        i32 stride = c.bw * (i32)8;
        for (i32 row = (i32)0; row < (i32)8; row = row + (i32)1)
            {
            i32 b = row * (i32)8;
            u8* out = c.plane + (by * (i32)8 + row) * stride + bx * (i32)8;
            i64 w0 = ws[b];
            i64 w1 = ws[b + (i32)1];
            i64 w2 = ws[b + (i32)2];
            i64 w3 = ws[b + (i32)3];
            i64 w4 = ws[b + (i32)4];
            i64 w5 = ws[b + (i32)5];
            i64 w6 = ws[b + (i32)6];
            i64 w7 = ws[b + (i32)7];
            if (w1 == (i64)0 && w2 == (i64)0 && w3 == (i64)0 && w4 == (i64)0 && w5 == (i64)0 && w6 == (i64)0 && w7 == (i64)0)
                {
                // DESCALE by PASS1_BITS + 3 = 5
                u8 dv = gJpegRange[(i32)((w0 + (i64)16) >> (i64)5) & (i32)1023];
                for (i32 x = (i32)0; x < (i32)8; x = x + (i32)1)
                    {
                    out[x] = dv;
                    }
                continue;
                }
            i64 z1 = (w2 + w6) * (i64)4433;
            i64 tmp2 = z1 + w6 * (i64)-15137;
            i64 tmp3 = z1 + w2 * (i64)6270;
            i64 tmp0 = (w0 + w4) << (i64)13;
            i64 tmp1 = (w0 - w4) << (i64)13;
            i64 tmp10 = tmp0 + tmp3;
            i64 tmp13 = tmp0 - tmp3;
            i64 tmp11 = tmp1 + tmp2;
            i64 tmp12 = tmp1 - tmp2;
            tmp0 = w7;
            tmp1 = w5;
            tmp2 = w3;
            tmp3 = w1;
            z1 = tmp0 + tmp3;
            i64 z2 = tmp1 + tmp2;
            i64 z3 = tmp0 + tmp2;
            i64 z4 = tmp1 + tmp3;
            i64 z5 = (z3 + z4) * (i64)9633;
            tmp0 = tmp0 * (i64)2446;
            tmp1 = tmp1 * (i64)16819;
            tmp2 = tmp2 * (i64)25172;
            tmp3 = tmp3 * (i64)12299;
            z1 = z1 * (i64)-7373;
            z2 = z2 * (i64)-20995;
            z3 = z3 * (i64)-16069;
            z4 = z4 * (i64)-3196;
            z3 = z3 + z5;
            z4 = z4 + z5;
            tmp0 = tmp0 + z1 + z3;
            tmp1 = tmp1 + z2 + z4;
            tmp2 = tmp2 + z2 + z3;
            tmp3 = tmp3 + z1 + z4;
            // DESCALE by CONST_BITS + PASS1_BITS + 3 = 18
            out[0] = gJpegRange[(i32)((tmp10 + tmp3 + (i64)131072) >> (i64)18) & (i32)1023];
            out[7] = gJpegRange[(i32)((tmp10 - tmp3 + (i64)131072) >> (i64)18) & (i32)1023];
            out[1] = gJpegRange[(i32)((tmp11 + tmp2 + (i64)131072) >> (i64)18) & (i32)1023];
            out[6] = gJpegRange[(i32)((tmp11 - tmp2 + (i64)131072) >> (i64)18) & (i32)1023];
            out[2] = gJpegRange[(i32)((tmp12 + tmp1 + (i64)131072) >> (i64)18) & (i32)1023];
            out[5] = gJpegRange[(i32)((tmp12 - tmp1 + (i64)131072) >> (i64)18) & (i32)1023];
            out[3] = gJpegRange[(i32)((tmp13 + tmp0 + (i64)131072) >> (i64)18) & (i32)1023];
            out[4] = gJpegRange[(i32)((tmp13 - tmp0 + (i64)131072) >> (i64)18) & (i32)1023];
            }
        }

    // ---- markers -------------------------------------------------------------------------------
    bool readDQT(i32 p, i32 l)
        {
        i32 e = p + l;
        while (p < e && !bad)
            {
            i32 pq = (i32)data[p] >> (i32)4;
            i32 tq = (i32)data[p] & (i32)15;
            p = p + (i32)1;
            if (tq > (i32)3)
                {
                return false;
                }
            for (i32 k = (i32)0; k < (i32)64; k = k + (i32)1)
                {
                i32 v = (i32)0;
                if (pq == (i32)0)
                    {
                    v = (i32)data[p];
                    p = p + (i32)1;
                    }
                else
                    {
                    v = self.u16at(p);
                    p = p + (i32)2;
                    }
                quant[tq * (i32)64 + gJpegZigzag[k]] = (u16)v;
                }
            }
        return !bad && p == e;
        }
    bool readDHT(i32 p, i32 l)
        {
        i32 e = p + l;
        while (p < e)
            {
            i32 tc = (i32)data[p] >> (i32)4;
            i32 th = (i32)data[p] & (i32)15;
            if (th > (i32)3 || tc > (i32)1 || p + (i32)17 > e)
                {
                return false;
                }
            i32 n = (i32)0;
            for (i32 i = (i32)1; i <= (i32)16; i = i + (i32)1)
                {
                n = n + (i32)data[p + i];
                }
            if (p + (i32)17 + n > e)
                {
                return false;
                }
            UXJpegHuff* t = tc == (i32)0 ? self.dcTab(th) : self.acTab(th);
            if (!t.build(data + p + (i32)1, data + p + (i32)17, n))
                {
                return false;
                }
            p = p + (i32)17 + n;
            }
        return true;
        }
    bool readSOF(i32 p, i32 l)
        {
        if (l < (i32)6 || (i32)data[p] != (i32)8)
            {
            return false; // 8-bit samples only
            }
        height = self.u16at(p + (i32)1);
        width = self.u16at(p + (i32)3);
        ncomp = (i32)data[p + (i32)5];
        if (width <= (i32)0 || height <= (i32)0 || (ncomp != (i32)1 && ncomp != (i32)3) || l < (i32)6 + ncomp * (i32)3)
            {
            return false; // a height of 0 (set by DNL) and CMYK are refused
            }
        hmax = (i32)1;
        vmax = (i32)1;
        for (i32 i = (i32)0; i < ncomp; i = i + (i32)1)
            {
            UXJpegComp* c = self.comp(i);
            c.id = (i32)data[p + (i32)6 + i * (i32)3];
            c.h = (i32)data[p + (i32)7 + i * (i32)3] >> (i32)4;
            c.v = (i32)data[p + (i32)7 + i * (i32)3] & (i32)15;
            c.tq = (i32)data[p + (i32)8 + i * (i32)3];
            if (c.h < (i32)1 || c.h > (i32)4 || c.v < (i32)1 || c.v > (i32)4 || c.tq > (i32)3)
                {
                return false;
                }
            hmax = c.h > hmax ? c.h : hmax;
            vmax = c.v > vmax ? c.v : vmax;
            }
        mcusX = (width + hmax * (i32)8 - (i32)1) / (hmax * (i32)8);
        mcusY = (height + vmax * (i32)8 - (i32)1) / (vmax * (i32)8);
        for (i32 i = (i32)0; i < ncomp; i = i + (i32)1)
            {
            UXJpegComp* c = self.comp(i);
            c.bw = mcusX * c.h;
            c.bh = mcusY * c.v;
            c.plane = new u8[(u32)(c.bw * c.bh * (i32)64)];
            }
        frameSeen = true;
        return true;
        }

    // A scan: its header at p (length l), then the entropy-coded data that follows it.
    bool readScan(i32 p, i32 l)
        {
        if (!frameSeen)
            {
            return false;
            }
        i32 ns = (i32)data[p];
        if (ns < (i32)1 || ns > ncomp || l < (i32)4 + ns * (i32)2)
            {
            return false;
            }
        UXJpegComp* sc[4];
        for (i32 i = (i32)0; i < ns; i = i + (i32)1)
            {
            i32 cid = (i32)data[p + (i32)1 + i * (i32)2];
            i32 tables = (i32)data[p + (i32)2 + i * (i32)2];
            UXJpegComp* found = (UXJpegComp*)0;
            for (i32 k = (i32)0; k < ncomp; k = k + (i32)1)
                {
                if (self.comp(k).id == cid)
                    {
                    found = self.comp(k);
                    }
                }
            if (found == (UXJpegComp*)0 || (tables >> (i32)4) > (i32)3 || (tables & (i32)15) > (i32)3)
                {
                return false;
                }
            found.td = tables >> (i32)4;
            found.ta = tables & (i32)15;
            found.pred = (i32)0;
            sc[i] = found;
            }
        pos = p + l;
        self.resetBits();
        // Interleaved: MCUs of every component's h x v blocks.  One component: its own blocks in
        // raster order over the part of the plane the image covers.
        i32 unitsX = mcusX;
        i32 unitsY = mcusY;
        if (ns == (i32)1)
            {
            UXJpegComp* c = sc[0];
            i32 cw = (width * c.h + hmax - (i32)1) / hmax;
            i32 ch = (height * c.v + vmax - (i32)1) / vmax;
            unitsX = (cw + (i32)7) / (i32)8;
            unitsY = (ch + (i32)7) / (i32)8;
            }
        i32 total = unitsX * unitsY;
        i32 left = restartInterval;
        for (i32 u = (i32)0; u < total && !bad; u = u + (i32)1)
            {
            if (restartInterval > (i32)0 && left == (i32)0)
                {
                // Expect RSTn: realign, step over it, and reset the predictions.
                self.skipToMarker();
                if (pos + (i32)1 < len && (i32)data[pos] == (i32)255 && (i32)data[pos + (i32)1] >= (i32)0xD0 && (i32)data[pos + (i32)1] <= (i32)0xD7)
                    {
                    pos = pos + (i32)2;
                    }
                self.resetBits();
                for (i32 i = (i32)0; i < ns; i = i + (i32)1)
                    {
                    sc[i].pred = (i32)0;
                    }
                left = restartInterval;
                }
            i32 mx = u % unitsX;
            i32 my = u / unitsX;
            if (ns == (i32)1)
                {
                self.decodeBlock(sc[0]);
                if (!bad)
                    {
                    self.idct(sc[0], mx, my);
                    }
                }
            else
                {
                for (i32 i = (i32)0; i < ns && !bad; i = i + (i32)1)
                    {
                    UXJpegComp* c = sc[i];
                    for (i32 yy = (i32)0; yy < c.v && !bad; yy = yy + (i32)1)
                        {
                        for (i32 xx = (i32)0; xx < c.h && !bad; xx = xx + (i32)1)
                            {
                            self.decodeBlock(c);
                            if (!bad)
                                {
                                self.idct(c, mx * c.h + xx, my * c.v + yy);
                                }
                            }
                        }
                    }
                }
            left = left - (i32)1;
            }
        self.skipToMarker();
        return !bad && !exhausted; // a file that ends mid-scan is refused, not padded with grey
        }
    // After entropy data: leave pos at the next marker (0xFF followed by a non-zero, non-0xFF byte).
    void skipToMarker(void)
        {
        if (markerHit)
            {
            return;
            }
        while (pos + (i32)1 < len)
            {
            if ((i32)data[pos] == (i32)255 && (i32)data[pos + (i32)1] != (i32)0 && (i32)data[pos + (i32)1] != (i32)255)
                {
                return;
                }
            pos = pos + (i32)1;
            }
        pos = len;
        }

    bool parse(void)
        {
        if (len < (i32)4 || (i32)data[0] != (i32)255 || (i32)data[1] != (i32)0xD8)
            {
            return false;
            }
        jpegBuildRange();
        pos = (i32)2;
        bool scanned = false;
        while (pos + (i32)3 < len)
            {
            if ((i32)data[pos] != (i32)255)
                {
                return false;
                }
            i32 m = (i32)data[pos + (i32)1];
            if (m == (i32)255)
                {
                pos = pos + (i32)1; // fill bytes
                continue;
                }
            if (m == (i32)0xD9)
                {
                break; // EOI
                }
            if (m >= (i32)0xD0 && m <= (i32)0xD7)
                {
                pos = pos + (i32)2; // a stray RSTn
                continue;
                }
            i32 l = self.u16at(pos + (i32)2);
            if (bad || l < (i32)2 || pos + (i32)2 + l > len)
                {
                return false;
                }
            i32 p = pos + (i32)4;
            i32 body = l - (i32)2;
            bool ok = true;
            if (m == (i32)0xC0 || m == (i32)0xC1)
                {
                ok = self.readSOF(p, body);
                }
            else if (m >= (i32)0xC2 && m <= (i32)0xCF && m != (i32)0xC4 && m != (i32)0xC8 && m != (i32)0xCC)
                {
                return false; // progressive, lossless, arithmetic: refused
                }
            else if (m == (i32)0xC4)
                {
                ok = self.readDHT(p, body);
                }
            else if (m == (i32)0xDB)
                {
                ok = self.readDQT(p, body);
                }
            else if (m == (i32)0xDD)
                {
                restartInterval = self.u16at(p);
                }
            else if (m == (i32)0xEE && body >= (i32)12 && (i32)data[p] == (i32)65 && (i32)data[p + (i32)1] == (i32)100)
                {
                adobeTransform = (i32)data[p + (i32)11]; // "Adobe" ... transform
                }
            else if (m == (i32)0xDA)
                {
                ok = self.readScan(p, body);
                scanned = scanned || ok;
                if (!ok)
                    {
                    return false;
                    }
                continue; // readScan left pos at the next marker
                }
            if (!ok)
                {
                return false;
                }
            pos = pos + (i32)2 + l;
            }
        return scanned && !bad;
        }

    // The planes to pixels: chroma replicated over its block of pixels, then libjpeg's YCbCr to RGB.
    UXImage* image(void)
        {
        UXImage* im = UXImage.make(width, height);
        UXJpegComp* c0 = self.comp(0);
        UXJpegComp* c1 = self.comp(1);
        UXJpegComp* c2 = self.comp(2);
        bool rgb = ncomp == (i32)3 && adobeTransform == (i32)0;
        for (i32 y = (i32)0; y < height; y = y + (i32)1)
            {
            for (i32 x = (i32)0; x < width; x = x + (i32)1)
                {
                i32 yy = (i32)c0.plane[(y * c0.v / vmax) * c0.bw * (i32)8 + x * c0.h / hmax];
                i32 r = yy;
                i32 g = yy;
                i32 b = yy;
                if (ncomp == (i32)3)
                    {
                    i32 cb = (i32)c1.plane[(y * c1.v / vmax) * c1.bw * (i32)8 + x * c1.h / hmax];
                    i32 cr = (i32)c2.plane[(y * c2.v / vmax) * c2.bw * (i32)8 + x * c2.h / hmax];
                    if (rgb)
                        {
                        g = cb;
                        b = cr;
                        }
                    else
                        {
                        // jdcolor.c: FIX(1.40200)=91881, FIX(1.77200)=116130, FIX(0.71414)=46802,
                        // FIX(0.34414)=22554, ONE_HALF = 32768, SCALEBITS 16.
                        i32 crx = cr - (i32)128;
                        i32 cbx = cb - (i32)128;
                        i32 crR = ((i32)91881 * crx + (i32)32768) >> (i32)16;
                        i32 cbB = ((i32)116130 * cbx + (i32)32768) >> (i32)16;
                        i32 gg = (((i32)-46802 * crx) + ((i32)-22554 * cbx + (i32)32768)) >> (i32)16;
                        r = yy + crR;
                        g = yy + gg;
                        b = yy + cbB;
                        }
                    }
                im.px[y * width + x] = (u32)$FF000000 | ((u32)jpegClamp(r) << (u32)16) |
                                       ((u32)jpegClamp(g) << (u32)8) | (u32)jpegClamp(b);
                }
            }
        return im;
        }

    // The decoder's one entry point: a UXImage of 0xFFRRGGBB pixels, or null for a file it refuses
    // or cannot read (see the list at the top).
    static UXImage* decode(u8* bytes, i32 n)
        {
        if (bytes == (u8*)0 || n <= (i32)0)
            {
            return (UXImage*)0;
            }
        UXJpeg* j = new UXJpeg();
        j.data = bytes;
        j.len = n;
        if (!j.parse())
            {
            return (UXImage*)0;
            }
        return j.image();
        }
    }
