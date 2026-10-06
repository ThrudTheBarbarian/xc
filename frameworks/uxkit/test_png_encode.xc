// test_png_encode.xc — UXPngEncode, the PNG writer (headless, every architecture).  Pictures of the
// kinds a UI makes -- a gradient, flat panels, noise, translucency, odd sizes -- are encoded and
// decoded again with UXPng: every pixel comes back the same, an opaque picture is written as RGB
// and a translucent one as RGBA, and flat content compresses.  PNG_ENCODE_DIR=<dir> also writes the
// files there, for an outside decoder to check.
#import <Stdio.xc>
#import "UXPng.xc"
#import "UXPngEncode.xc"
#import "UXImage.xc"
#import "Data.xc"
#import "UXString.xc"
#import "UXFileIO.xc"
#if !ARCH_wasm32
u8* getenv(u8* name);
#endif

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
u32 gSeed;
u32 rnd(void)
    {
    gSeed = gSeed * (u32)1103515245 + (u32)12345;
    return (gSeed >> (u32)8) & (u32)$FFFFFF;
    }
UXImage* pic(i32 kind, i32 w, i32 h)
    {
    UXImage* im = UXImage.make(w, h);
    for (i32 y = (i32)0; y < h; y = y + (i32)1)
        {
        for (i32 x = (i32)0; x < w; x = x + (i32)1)
            {
            u32 v = (u32)0;
            if (kind == (i32)0) // gradient
                {
                v = (u32)$FF000000 | ((u32)(x * (i32)255 / (w > (i32)1 ? w - (i32)1 : (i32)1)) << (u32)16) | ((u32)(y * (i32)255 / (h > (i32)1 ? h - (i32)1 : (i32)1)) << (u32)8) | (u32)128;
                }
            else if (kind == (i32)1) // flat panels and a rule, as a window is
                {
                v = x < w / (i32)3 ? (u32)$FFEDEDED : (y % (i32)40 == (i32)0 ? (u32)$FF404040 : (u32)$FFFFFFFF);
                }
            else if (kind == (i32)2) // noise
                {
                v = (u32)$FF000000 | rnd();
                }
            else // translucency: alpha across, colour down, and a fully clear corner
                {
                u32 a = (u32)(x * (i32)255 / (w > (i32)1 ? w - (i32)1 : (i32)1));
                v = (a << (u32)24) | (rnd() & (u32)$FFFFFF);
                if (x < (i32)4 && y < (i32)4)
                    {
                    v = (u32)0;
                    }
                }
            im.px[y * w + x] = v;
            }
        }
    return im;
    }
bool same(UXImage* a, UXImage* b)
    {
    if (a == (UXImage*)0 || b == (UXImage*)0 || a.w != b.w || a.h != b.h)
        {
        return false;
        }
    for (i32 i = (i32)0; i < a.w * a.h; i = i + (i32)1)
        {
        if (a.px[i] != b.px[i])
            {
            return false;
            }
        }
    return true;
    }
void one(u8* name, i32 kind, i32 w, i32 h)
    {
    UXImage* im = pic(kind, w, h);
    Data* png = UXPngEncode.encode(im);
    UXImage* back = png != (Data*)0 ? UXPng.decode(png.bytes(), png.length()) : (UXImage*)0;
    i32 ct = png != (Data*)0 && png.length() > (i32)25 ? (i32)png.bytes()[25] : (i32)-1;
    Stdio.printf("  (%s %dx%d: %d bytes from %d, colour type %d)\n", name, w, h, png != (Data*)0 ? png.length() : (i32)0, w * h * (i32)4, ct);
    ck(name, same(im, back));
#if !ARCH_wasm32
    u8* dir = getenv((u8*)"PNG_ENCODE_DIR");
#else
    u8* dir = (u8*)0; // no environment on wasm32
#endif
    if (dir != (u8*)0 && png != (Data*)0)
        {
        Data* path = UXStr.toData(dir);
        path.appendByte((u8)47);
        path.append(UXStr.toData(name));
        path.append(UXStr.toData((u8*)".png"));
        path.appendByte((u8)0);
        UXFileIO.write(path.bytes(), png);
        }
    }
void main(void)
    {
    gFails = (i32)0;
    gSeed = (u32)7;
    one((u8*)"gradient", (i32)0, (i32)256, (i32)128);
    one((u8*)"window", (i32)1, (i32)640, (i32)400);
    one((u8*)"noise", (i32)2, (i32)97, (i32)61);
    one((u8*)"alpha", (i32)3, (i32)120, (i32)80);
    one((u8*)"tiny", (i32)2, (i32)1, (i32)1);
    one((u8*)"odd", (i32)3, (i32)37, (i32)13);
    Data* op = UXPng.encode(pic((i32)1, (i32)64, (i32)64));
    Data* tr = UXPngEncode.encode(pic((i32)3, (i32)64, (i32)64));
    ck((u8*)"an opaque picture is written as RGB, a translucent one as RGBA", op.bytes()[25] == (u8)2 && tr.bytes()[25] == (u8)6);
    Data* flat = UXPngEncode.encode(pic((i32)1, (i32)640, (i32)400));
    ck((u8*)"a flat window picture compresses to under 1% of its pixels", flat.length() * (i32)100 < (i32)640 * (i32)400 * (i32)4);
    ck((u8*)"an empty image gives no file", UXPngEncode.encode((UXImage*)0) == (Data*)0);
    Stdio.printf(gFails == (i32)0 ? "PASS: UXPngEncode -- pixels back exactly, RGB or RGBA, compressed\n" : "FAIL: %d\n", gFails);
    }
