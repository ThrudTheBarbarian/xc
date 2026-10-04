// UXPngEncode.xc — a PNG encoder, in xc: UXPngEncode.encode(UXImage*) -> UXData, the file's bytes.
//
// The writing half of UXPng, for pictures an app saves (a snapshot, a test probe's frame).  It
// writes 8-bit RGB when every pixel is opaque and 8-bit RGBA otherwise, non-interlaced, with the
// pixels as UXImage holds them (0xAARRGGBB, not premultiplied), so UXPng.decode of the result gives
// back the same words.
//
// Each row takes the filter whose output has the smallest sum of absolute values (the heuristic
// libpng uses), and the filtered rows are deflated with LZ77 over a 32K window (hash chains on the
// next three bytes, the longest match up to 258) coded with deflate's FIXED Huffman tables.  Fixed
// codes cost a little against dynamic ones but need no tables in the stream, and a UI picture --
// large flat runs -- compresses mostly through the matches.
#import "UXImage.xc"
#import "UXData.xc"
#import "UXLibc.xc" // malloc, free

// LSB-first bit writer onto a UXData, as deflate packs its stream
class UXPngBits : Object
    {
    UXData* out;
    u32 acc;
    i32 n;
    void init(void)
        {
        out = UXData.withCapacity((i32)65536);
        acc = (u32)0;
        n = (i32)0;
        }
    void put(u32 v, i32 bits)
        {
        acc = acc | (v << (u32)n);
        n = n + bits;
        while (n >= (i32)8)
            {
            out.appendByte((u8)(acc & (u32)255));
            acc = acc >> (u32)8;
            n = n - (i32)8;
            }
        }
    // a Huffman code goes in most-significant bit first
    void code(u32 c, i32 bits)
        {
        u32 r = (u32)0;
        for (i32 i = (i32)0; i < bits; i = i + (i32)1)
            {
            r = (r << (u32)1) | ((c >> (u32)i) & (u32)1);
            }
        self.put(r, bits);
        }
    void flush(void)
        {
        if (n > (i32)0)
            {
            out.appendByte((u8)(acc & (u32)255));
            }
        acc = (u32)0;
        n = (i32)0;
        }
    }

class UXPngEncode
    {
    // ---- the fixed Huffman code (RFC 1951 3.2.6) ----------------------------------------
    static void literal(UXPngBits* b, i32 v)
        {
        if (v < (i32)144)
            {
            b.code((u32)((i32)$30 + v), (i32)8);
            }
        else if (v < (i32)256)
            {
            b.code((u32)((i32)$190 + v - (i32)144), (i32)9);
            }
        else if (v < (i32)280)
            {
            b.code((u32)(v - (i32)256), (i32)7);
            }
        else
            {
            b.code((u32)((i32)$C0 + v - (i32)280), (i32)8);
            }
        }
    // a match: its length (3..258) and distance (1..32768), each a code plus extra bits
    static void match(UXPngBits* b, i32 len, i32 dist)
        {
        i32 lbase[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
        i32 lext[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
        i32 dbase[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
        i32 dext[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};
        i32 li = (i32)28;
        while (lbase[li] > len)
            {
            li = li - (i32)1;
            }
        UXPngEncode.literal(b, (i32)257 + li);
        if (lext[li] > (i32)0)
            {
            b.put((u32)(len - lbase[li]), lext[li]);
            }
        i32 di = (i32)29;
        while (dbase[di] > dist)
            {
            di = di - (i32)1;
            }
        b.code((u32)di, (i32)5);
        if (dext[di] > (i32)0)
            {
            b.put((u32)(dist - dbase[di]), dext[di]);
            }
        }

    // ---- zlib: a deflate stream of one fixed-Huffman block, then the Adler-32 ---------------
    static UXData* zlib(u8* src, i32 n)
        {
        UXPngBits* b = new UXPngBits();
        b.out.appendByte((u8)$78); // deflate, 32K window
        b.out.appendByte((u8)$01); // no dictionary, fastest; (0x78 << 8 | 0x01) % 31 == 0
        b.put((u32)1, (i32)1);     // BFINAL
        b.put((u32)1, (i32)2);     // BTYPE 01, fixed codes
        // hash chains: head[h] the latest position whose next three bytes hash to h, prev[i & 32767]
        // the one before it
        i32* head = (i32*)malloc((u32)65536 * (u32)4);
        i32* prev = (i32*)malloc((u32)32768 * (u32)4);
        for (i32 i = (i32)0; i < (i32)65536; i = i + (i32)1)
            {
            head[i] = (i32)-1;
            }
        i32 p = (i32)0;
        while (p < n)
            {
            i32 best = (i32)0;
            i32 bestD = (i32)0;
            if (p + (i32)3 <= n)
                {
                i32 h = (((i32)src[p] << (i32)8) ^ ((i32)src[p + (i32)1] << (i32)4) ^ (i32)src[p + (i32)2]) & (i32)65535;
                i32 c = head[h];
                i32 tries = (i32)64;
                i32 maxLen = n - p < (i32)258 ? n - p : (i32)258;
                while (c >= (i32)0 && p - c <= (i32)32768 && tries > (i32)0)
                    {
                    if (src[c + best] == src[p + best])
                        {
                        i32 l = (i32)0;
                        while (l < maxLen && src[c + l] == src[p + l])
                            {
                            l = l + (i32)1;
                            }
                        if (l > best)
                            {
                            best = l;
                            bestD = p - c;
                            if (l == maxLen)
                                {
                                break;
                                }
                            }
                        }
                    c = prev[c & (i32)32767];
                    tries = tries - (i32)1;
                    }
                }
            i32 step = best >= (i32)3 ? best : (i32)1;
            if (best >= (i32)3)
                {
                UXPngEncode.match(b, best, bestD);
                }
            else
                {
                UXPngEncode.literal(b, (i32)src[p]);
                }
            // enter every position passed into the chains
            for (i32 k = (i32)0; k < step; k = k + (i32)1)
                {
                i32 q = p + k;
                if (q + (i32)3 <= n)
                    {
                    i32 hq = (((i32)src[q] << (i32)8) ^ ((i32)src[q + (i32)1] << (i32)4) ^ (i32)src[q + (i32)2]) & (i32)65535;
                    prev[q & (i32)32767] = head[hq];
                    head[hq] = q;
                    }
                }
            p = p + step;
            }
        UXPngEncode.literal(b, (i32)256); // end of block
        b.flush();
        free((pointer)head);
        free((pointer)prev);
        u32 s1 = (u32)1;
        u32 s2 = (u32)0;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            s1 = (s1 + (u32)src[i]) % (u32)65521;
            s2 = (s2 + s1) % (u32)65521;
            }
        UXPngEncode.be32(b.out, (s2 << (u32)16) | s1);
        return b.out;
        }

    // ---- chunks ----------------------------------------------------------------------------
    static void be32(UXData* d, u32 v)
        {
        d.appendByte((u8)((v >> (u32)24) & (u32)255));
        d.appendByte((u8)((v >> (u32)16) & (u32)255));
        d.appendByte((u8)((v >> (u32)8) & (u32)255));
        d.appendByte((u8)(v & (u32)255));
        }
    static u32 crc(u32 c, u8* p, i32 n)
        {
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            c = c ^ (u32)p[i];
            for (i32 k = (i32)0; k < (i32)8; k = k + (i32)1)
                {
                c = (c & (u32)1) != (u32)0 ? (u32)$EDB88320 ^ (c >> (u32)1) : c >> (u32)1;
                }
            }
        return c;
        }
    static void chunk(UXData* d, u8* type, u8* body, i32 n)
        {
        UXPngEncode.be32(d, (u32)n);
        d.appendBytes(type, (i32)4);
        if (n > (i32)0)
            {
            d.appendBytes(body, n);
            }
        u32 c = UXPngEncode.crc((u32)$FFFFFFFF, type, (i32)4);
        c = UXPngEncode.crc(c, body, n);
        UXPngEncode.be32(d, c ^ (u32)$FFFFFFFF);
        }

    // ---- filters ---------------------------------------------------------------------------
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
        return pb <= pc ? b : c;
        }
    // row filtered by type f into out[0..stride-1]; its cost, the sum of |byte as signed|
    static i32 filterRow(i32 f, u8* row, u8* up, i32 stride, i32 bpp, u8* out)
        {
        i32 cost = (i32)0;
        for (i32 i = (i32)0; i < stride; i = i + (i32)1)
            {
            i32 a = i >= bpp ? (i32)row[i - bpp] : (i32)0;
            i32 b = up != (u8*)0 ? (i32)up[i] : (i32)0;
            i32 c = i >= bpp && up != (u8*)0 ? (i32)up[i - bpp] : (i32)0;
            i32 x = (i32)row[i];
            i32 v = x;
            if (f == (i32)1)
                {
                v = x - a;
                }
            else if (f == (i32)2)
                {
                v = x - b;
                }
            else if (f == (i32)3)
                {
                v = x - (a + b) / (i32)2;
                }
            else if (f == (i32)4)
                {
                v = x - UXPngEncode.paeth(a, b, c);
                }
            u8 o = (u8)(v & (i32)255);
            out[i] = o;
            i32 sv = (i32)o < (i32)128 ? (i32)o : (i32)256 - (i32)o;
            cost = cost + sv;
            }
        return cost;
        }

    // The image as a PNG file's bytes; null for an empty image.
    static UXData* encode(UXImage* img)
        {
        if (img == (UXImage*)0 || img.px == (u32*)0 || img.w <= (i32)0 || img.h <= (i32)0)
            {
            return (UXData*)0;
            }
        i32 w = img.w;
        i32 h = img.h;
        bool alpha = false;
        for (i32 i = (i32)0; i < w * h; i = i + (i32)1)
            {
            if ((img.px[i] >> (u32)24) != (u32)255)
                {
                alpha = true;
                break;
                }
            }
        i32 bpp = alpha ? (i32)4 : (i32)3;
        i32 stride = w * bpp;
        // the raw rows, then each row's filter byte and filtered bytes
        u8* raw = (u8*)malloc((u32)(stride * h));
        for (i32 y = (i32)0; y < h; y = y + (i32)1)
            {
            for (i32 x = (i32)0; x < w; x = x + (i32)1)
                {
                u32 v = img.px[y * w + x];
                u8* q = raw + y * stride + x * bpp;
                q[0] = (u8)((v >> (u32)16) & (u32)255);
                q[1] = (u8)((v >> (u32)8) & (u32)255);
                q[2] = (u8)(v & (u32)255);
                if (alpha)
                    {
                    q[3] = (u8)((v >> (u32)24) & (u32)255);
                    }
                }
            }
        u8* filt = (u8*)malloc((u32)((stride + (i32)1) * h));
        u8* tryBuf = (u8*)malloc((u32)stride);
        for (i32 y = (i32)0; y < h; y = y + (i32)1)
            {
            u8* row = raw + y * stride;
            u8* up = y > (i32)0 ? raw + (y - (i32)1) * stride : (u8*)0;
            u8* dst = filt + y * (stride + (i32)1);
            i32 bestF = (i32)0;
            i32 bestCost = UXPngEncode.filterRow((i32)0, row, up, stride, bpp, dst + (i32)1);
            for (i32 f = (i32)1; f <= (i32)4; f = f + (i32)1)
                {
                i32 cst = UXPngEncode.filterRow(f, row, up, stride, bpp, tryBuf);
                if (cst < bestCost)
                    {
                    bestCost = cst;
                    bestF = f;
                    for (i32 i = (i32)0; i < stride; i = i + (i32)1)
                        {
                        dst[(i32)1 + i] = tryBuf[i];
                        }
                    }
                }
            dst[0] = (u8)bestF;
            }
        UXData* z = UXPngEncode.zlib(filt, (stride + (i32)1) * h);
        free((pointer)raw);
        free((pointer)filt);
        free((pointer)tryBuf);

        UXData* d = UXData.withCapacity(z.length() + (i32)64);
        u8 sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
        d.appendBytes(&sig[0], (i32)8);
        u8 ihdr[13];
        ihdr[0] = (u8)((w >> (i32)24) & (i32)255);
        ihdr[1] = (u8)((w >> (i32)16) & (i32)255);
        ihdr[2] = (u8)((w >> (i32)8) & (i32)255);
        ihdr[3] = (u8)(w & (i32)255);
        ihdr[4] = (u8)((h >> (i32)24) & (i32)255);
        ihdr[5] = (u8)((h >> (i32)16) & (i32)255);
        ihdr[6] = (u8)((h >> (i32)8) & (i32)255);
        ihdr[7] = (u8)(h & (i32)255);
        ihdr[8] = (u8)8;                         // bit depth
        ihdr[9] = alpha ? (u8)6 : (u8)2;         // RGBA or RGB
        ihdr[10] = (u8)0;                        // deflate
        ihdr[11] = (u8)0;                        // adaptive filtering
        ihdr[12] = (u8)0;                        // not interlaced
        UXPngEncode.chunk(d, (u8*)"IHDR", &ihdr[0], (i32)13);
        UXPngEncode.chunk(d, (u8*)"IDAT", z.bytes(), z.length());
        UXPngEncode.chunk(d, (u8*)"IEND", (u8*)0, (i32)0);
        return d;
        }
    }
