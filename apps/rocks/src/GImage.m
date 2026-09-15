// GImage.m — see GImage.h.

#import "GImage.h"

// Build an NSImage from RGBA8888 pixels (w*h*4, top-down).
static NSImage* imageFromRGBA(const unsigned char* px, int w, int h)
    {
    NSBitmapImageRep* rep =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                pixelsWide:w
                                                pixelsHigh:h
                                             bitsPerSample:8
                                           samplesPerPixel:4
                                                  hasAlpha:YES
                                                  isPlanar:NO
                                            colorSpaceName:NSDeviceRGBColorSpace
                                              bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                                               bytesPerRow:w * 4
                                              bitsPerPixel:32];
    memcpy(rep.bitmapData, px, (size_t)w * h * 4);
    NSImage* img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [img addRepresentation:rep];
    return img;
    }

NSImage* GImageFromPAM(NSData* data)
    {
    const unsigned char* p = data.bytes;
    NSUInteger len = data.length;
    if (len < 3 || p[0] != 'P' || p[1] != '7')
        return nil;
    NSUInteger i = 2;
    int w = 0, h = 0, depth = 0, maxval = 255;
    // parse header lines until ENDHDR
    while (i < len)
        {
        // read a line
        NSUInteger start = i;
        while (i < len && p[i] != '\n')
            i++;
        NSString* line = [[NSString alloc] initWithBytes:p + start
                                                  length:i - start
                                                encoding:NSASCIIStringEncoding]
                             ?: @"";
        if (i < len)
            i++; // skip newline
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"ENDHDR"])
            break;
        if ([line hasPrefix:@"WIDTH"])
            w = [[line substringFromIndex:5] intValue];
        else if ([line hasPrefix:@"HEIGHT"])
            h = [[line substringFromIndex:6] intValue];
        else if ([line hasPrefix:@"DEPTH"])
            depth = [[line substringFromIndex:5] intValue];
        else if ([line hasPrefix:@"MAXVAL"])
            maxval = [[line substringFromIndex:6] intValue];
        }
    if (w <= 0 || h <= 0 || depth < 1 || depth > 4 || maxval != 255)
        return nil;
    NSUInteger need = (NSUInteger)w * h * depth;
    if (len - i < need)
        return nil;
    const unsigned char* raw = p + i;

    unsigned char* rgba = malloc((size_t)w * h * 4);
    for (int y = 0; y < h; y++)
        {
        for (int x = 0; x < w; x++)
            {
            const unsigned char* s = raw + ((size_t)y * w + x) * depth;
            unsigned char r, g, b, a;
            switch (depth)
                {
            case 1:
                r = g = b = s[0];
                a = 255;
                break;
            case 2:
                r = g = b = s[0];
                a = s[1];
                break;
            case 4:
                r = s[0];
                g = s[1];
                b = s[2];
                a = s[3];
                break;
            default:
                r = s[0];
                g = s[1];
                b = s[2];
                a = 255;
                break; // 3
                }
            unsigned char* d = rgba + ((size_t)y * w + x) * 4;
            d[0] = r;
            d[1] = g;
            d[2] = b;
            d[3] = a;
            }
        }
    NSImage* img = imageFromRGBA(rgba, w, h);
    free(rgba);
    return img;
    }

NSData* GPAMFromImage(NSImage* image)
    {
    NSSize sz = image.size;
    int w = (int)sz.width, h = (int)sz.height;
    if (w <= 0 || h <= 0)
        return nil;
    NSBitmapImageRep* rep =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                pixelsWide:w
                                                pixelsHigh:h
                                             bitsPerSample:8
                                           samplesPerPixel:4
                                                  hasAlpha:YES
                                                  isPlanar:NO
                                            colorSpaceName:NSDeviceRGBColorSpace
                                               bytesPerRow:w * 4
                                              bitsPerPixel:32];
    NSGraphicsContext* ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    [image drawInRect:NSMakeRect(0, 0, w, h)];
    [NSGraphicsContext restoreGraphicsState];

    NSMutableData* out = [NSMutableData data];
    NSString* hdr = [NSString stringWithFormat:
                                  @"P7\nWIDTH %d\nHEIGHT %d\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n", w, h];
    [out appendData:[hdr dataUsingEncoding:NSASCIIStringEncoding]];
    unsigned char* bd = rep.bitmapData;
    NSUInteger bpr = rep.bytesPerRow;
    for (int y = 0; y < h; y++)
        {
        [out appendBytes:bd + (NSUInteger)y * bpr length:(NSUInteger)w * 4];
        }
    return out;
    }

NSImage* GImageFromMono(NSData* data, NSData* mask, int w, int h)
    {
    if (!data || w <= 0 || h <= 0)
        return nil;
    int wordW = ((w + 15) / 16) * 16; // rows padded to 16-bit boundary
    int stride = wordW / 8;
    const unsigned char* d = data.bytes;
    const unsigned char* m = mask.bytes;
    NSUInteger dlen = data.length, mlen = mask.length;
    unsigned char* rgba = calloc((size_t)w * h * 4, 1);
    for (int y = 0; y < h; y++)
        {
        for (int x = 0; x < w; x++)
            {
            NSUInteger bit = (NSUInteger)y * stride + (x / 8);
            int shift = 7 - (x & 7);
            int on = (bit < dlen) ? ((d[bit] >> shift) & 1) : 0;
            int opaque = m ? ((bit < mlen) ? ((m[bit] >> shift) & 1) : 0) : 1;
            unsigned char* px = rgba + ((size_t)y * w + x) * 4;
            if (opaque)
                {
                unsigned char v = on ? 0 : 255; // set bit -> black
                px[0] = px[1] = px[2] = v;
                px[3] = 255;
                }
            }
        }
    NSImage* img = imageFromRGBA(rgba, w, h);
    free(rgba);
    return img;
    }

// ---- Atari colour icon (CICONBLK) -> RGBA PAM ------------------------------

// The standard VDI palette, used when a file carries no palette of its own.
// Index order is the VDI's, so a 4-plane icon lands on the colours GEM intended.
static const uint8_t kVDIPalette[16][3] = {
    {255, 255, 255}, {0, 0, 0}, {255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {0, 255, 255}, {255, 255, 0}, {255, 0, 255}, {192, 192, 192}, {128, 128, 128}, {128, 0, 0}, {0, 128, 0}, {0, 0, 128}, {0, 128, 128}, {128, 128, 0}, {128, 0, 128}};

NSData* GPAMFromPlanar(NSData* data, NSData* mask, int w, int h, int planes,
                       const uint8_t* palette)
    {
    if (w <= 0 || h <= 0 || planes <= 0 || planes > 8)
        return nil;

    const int wordsPerRow = (w + 15) / 16; // rows are padded to 16 bits
    const size_t planeBytes = (size_t)wordsPerRow * 2 * (size_t)h;
    if (data.length < planeBytes * (size_t)planes)
        return nil;
    if (mask && mask.length < planeBytes)
        mask = nil;

    const uint8_t* src = data.bytes;
    const uint8_t* msk = mask.bytes;

    NSMutableData* rgba = [NSMutableData dataWithLength:(NSUInteger)w * h * 4];
    uint8_t* out = rgba.mutableBytes;

    for (int y = 0; y < h; y++)
        {
        for (int x = 0; x < w; x++)
            {
            // Assemble the colour index from one bit per plane, plane 0 lowest.
            // The file holds VDI *standard* format (MFDB fd_stand = 1), which is
            // plane-SEQUENTIAL: the whole of plane 0, then the whole of plane 1.
            // (Device format — word-interleaved — is what the screen uses, not the file.)
            int word = x >> 4, bit = 15 - (x & 15);
            int index = 0;
            for (int p = 0; p < planes; p++)
                {
                size_t off = (size_t)p * planeBytes + ((size_t)y * wordsPerRow + word) * 2;
                if (off + 1 >= data.length)
                    continue;
                uint16_t wv = (uint16_t)((src[off] << 8) | src[off + 1]);
                if (wv & (1u << bit))
                    index |= (1 << p);
                }
            uint8_t a = 255;
            if (msk)
                {
                size_t off = ((size_t)y * wordsPerRow + word) * 2;
                uint16_t mv = (uint16_t)((msk[off] << 8) | msk[off + 1]);
                a = (mv & (1u << bit)) ? 255 : 0; // mask bit set = opaque
                }
            const uint8_t* rgb = palette ? palette + 3 * index
                                         : kVDIPalette[index & 15];
            uint8_t* px = out + ((size_t)y * w + x) * 4;
            px[0] = rgb[0];
            px[1] = rgb[1];
            px[2] = rgb[2];
            px[3] = a;
            }
        }

    NSString* hdr = [NSString stringWithFormat:
                                  @"P7\nWIDTH %d\nHEIGHT %d\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n", w, h];
    NSMutableData* pam = [[hdr dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [pam appendData:rgba];
    return pam;
    }

// ---- classic BITBLK (monochrome bit form) ----------------------------------

NSImage* GImageFromBitblk(NSData* data, int wb, int hl, int color)
    {
    if (!data || wb <= 0 || hl <= 0)
        return nil;
    if (data.length < (NSUInteger)wb * hl)
        return nil;
    int w = wb * 8, h = hl;

    // VDI pen for the set bits; anything out of range falls back to black.
    const uint8_t* pen = (color >= 0 && color < 16) ? kVDIPalette[color] : kVDIPalette[1];
    const uint8_t* src = data.bytes;

    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:w
                                                                    pixelsHigh:h
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:w * 4
                                                                  bitsPerPixel:32];
    uint8_t* out = rep.bitmapData;

    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            {
            int byte = src[(size_t)y * wb + (x >> 3)];
            BOOL set = (byte >> (7 - (x & 7))) & 1;
            uint8_t* px = out + ((size_t)y * w + x) * 4;
            // premultiplied: a clear bit is fully transparent, not white
            px[0] = set ? pen[0] : 0;
            px[1] = set ? pen[1] : 0;
            px[2] = set ? pen[2] : 0;
            px[3] = set ? 255 : 0;
            }

    NSImage* img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [img addRepresentation:rep];
    return img;
    }

// ---- AES mouse cursor (MFORM) ----------------------------------------------

BOOL GBitblkIsMform(NSData* data, int wb, int hl)
    {
    // 2 bytes per row, 37 rows = 5 header words + 16 mask + 16 data
    return wb == 2 && hl == 37 && data.length >= 74;
    }

NSImage* GImageFromMform(NSData* data, int* hotX, int* hotY)
    {
    if (!GBitblkIsMform(data, 2, 37))
        return nil;
    const uint8_t* b = data.bytes;
#define W(i) ((uint16_t)((b[(i) * 2] << 8) | b[(i) * 2 + 1]))

    if (hotX)
        *hotX = (int16_t)W(0);
    if (hotY)
        *hotY = (int16_t)W(1);
    int bg = (int16_t)W(3), fg = (int16_t)W(4); // note: bg comes before fg
    const uint8_t* bgc = (bg >= 0 && bg < 16) ? kVDIPalette[bg] : kVDIPalette[0];
    const uint8_t* fgc = (fg >= 0 && fg < 16) ? kVDIPalette[fg] : kVDIPalette[1];

    const int N = 16;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:N
                                                                    pixelsHigh:N
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:N * 4
                                                                  bitsPerPixel:32];
    uint8_t* out = rep.bitmapData;

    for (int y = 0; y < N; y++)
        {
        uint16_t mrow = W(5 + y);      // mask
        uint16_t drow = W(5 + 16 + y); // data
        for (int x = 0; x < N; x++)
            {
            int bit = 15 - x;
            BOOL opaque = (mrow >> bit) & 1;
            BOOL ink = (drow >> bit) & 1;
            const uint8_t* c = ink ? fgc : bgc;
            uint8_t* px = out + ((size_t)y * N + x) * 4;
            // premultiplied; a clear mask bit is fully transparent
            px[0] = opaque ? c[0] : 0;
            px[1] = opaque ? c[1] : 0;
            px[2] = opaque ? c[2] : 0;
            px[3] = opaque ? 255 : 0;
            }
        }
#undef W
    NSImage* img = [[NSImage alloc] initWithSize:NSMakeSize(N, N)];
    [img addRepresentation:rep];
    return img;
    }
