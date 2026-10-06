// test_movie.xc — UXMovie: frames in, a WebM file out (in the headless suite, and the movie gate's
// source).  It checks what can be checked without a decoder: frames counted and held, a repeated
// frame not encoded again, the wrong size refused, RGBA and UXImage input giving the same bytes, the
// file's EBML structure, nothing added after finish, and the encoder's own reconstruction close to
// its source.  It prints a checksum of the file, which must be the same on every arch.  Built with
// -D MOVIE_FILES it also writes test_movie.webm, the last frame as the encoder reconstructed it
// (test_movie_last.yuv) and that frame's source (test_movie_last.rgb), for run_movie.sh to hand to
// ffmpeg and a browser.
#import <Stdio.xc>
#import "UXMovie.xc"
#if MOVIE_FILES
#import "UXFileIO.xc"
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

// a frame like a UI's: a gradient backdrop, flat panels, one-pixel strokes and a moving box
UXImage* picture(i32 w, i32 h, i32 k)
    {
    UXImage* im = UXImage.make(w, h);
    for (i32 y = (i32)0; y < h; y = y + (i32)1)
        {
        for (i32 x = (i32)0; x < w; x = x + (i32)1)
            {
            i32 r = (x * (i32)255) / w;
            i32 g = (y * (i32)255) / h;
            i32 b = (i32)96;
            if (x > (i32)10 && x < w / (i32)3 && y > (i32)10 && y < h - (i32)10)
                {
                r = (i32)236;
                g = (i32)236;
                b = (i32)240; // a panel
                if ((y % (i32)12) < (i32)8 && (x % (i32)6) < (i32)4 && ((x * (i32)7 + y * (i32)3) % (i32)5) != (i32)0)
                    {
                    r = (i32)30;
                    g = (i32)30;
                    b = (i32)30; // its "text"
                    }
                }
            if (x > (i32)60 + k * (i32)5 && x < (i32)100 + k * (i32)5 && y > (i32)30 && y < (i32)70)
                {
                r = (i32)200;
                g = (i32)40;
                b = (i32)40; // the moving box
                }
            im.px[y * w + x] = (u32)$FF000000 | ((u32)r << (u32)16) | ((u32)g << (u32)8) | (u32)b;
            }
        }
    return im;
    }
Data* rgbaOf(UXImage* im)
    {
    Data* d = Data.withCapacity((u32)(im.w * im.h * (i32)4));
    for (i32 i = (i32)0; i < im.w * im.h; i = i + (i32)1)
        {
        u32 v = im.px[i];
        d.appendByte((u8)((v >> (u32)16) & (u32)255));
        d.appendByte((u8)((v >> (u32)8) & (u32)255));
        d.appendByte((u8)(v & (u32)255));
        d.appendByte((u8)(v >> (u32)24));
        }
    return d;
    }
u32 checksum(Data* d)
    {
    u32 s = (u32)2166136261; // FNV-1a
    for (i32 i = (i32)0; i < d.length(); i = i + (i32)1)
        {
        s = (s ^ (u32)d.byteAt(i)) * (u32)16777619;
        }
    return s;
    }
bool contains(Data* d, u8* s)
    {
    i32 n = (i32)0;
    while (s[n] != (u8)0)
        {
        n = n + (i32)1;
        }
    for (i32 i = (i32)0; i + n <= d.length(); i = i + (i32)1)
        {
        i32 k = (i32)0;
        while (k < n && d.byteAt(i + k) == s[k])
            {
            k = k + (i32)1;
            }
        if (k == n)
            {
            return true;
            }
        }
    return false;
    }

void main(void)
    {
    gFails = (i32)0;
    i32 w = (i32)203; // not a multiple of 16 either way: the edge macroblocks are padded
    i32 h = (i32)117;
    UXMovie* m = UXMovie.make(w, h, (i32)25);
    for (i32 k = (i32)0; k < (i32)5; k = k + (i32)1)
        {
        m.addHeld(picture(w, h, k), (i32)2);
        }
    ck((u8*)"five frames, each two ticks: 400 ms", m.frameCount() == (i32)5 && m.durationMs() == (i32)400);
    ck((u8*)"the same frame again is held, not encoded again", m.add(picture(w, h, (i32)4)) && m.frameCount() == (i32)5 && m.durationMs() == (i32)440);
    ck((u8*)"a frame of the wrong size is refused", !m.add(UXImage.make(w + (i32)1, h)) && m.frameCount() == (i32)5);
    ck((u8*)"...and so are no ticks", !m.addHeld(picture(w, h, (i32)9), (i32)0));

    // the encoder's own reconstruction of the last frame, against its source (luma, PSNR)
    UXVp8Encoder* e = m.enc;
    i64 se = (i64)0;
    for (i32 y = (i32)0; y < h; y = y + (i32)1)
        {
        for (i32 x = (i32)0; x < w; x = x + (i32)1)
            {
            i32 dd = (i32)e.srcY[y * e.yp + x] - (i32)e.recY[y * e.yp + x];
            se = se + (i64)(dd * dd);
            }
        }
    i64 mse100 = se * (i64)100 / (i64)(w * h); // mean squared error, in hundredths
    Stdio.printf("  (luma mean squared error %ld.%02ld)\n", mse100 / (i64)100, mse100 % (i64)100);
    ck((u8*)"the reconstruction is close to the source (luma PSNR above 40 dB)", mse100 < (i64)650);

#if MOVIE_FILES
    UXFileIO.write((u8*)"test_movie_last.yuv", m.reconstruction());
    Data* src = rgbaOf(picture(w, h, (i32)4));
    Data* rgb = Data.withCapacity((u32)(w * h * (i32)3));
    for (i32 i = (i32)0; i < w * h; i = i + (i32)1)
        {
        rgb.appendBytes(src.bytes() + (i64)(i * (i32)4), (i32)3);
        }
    UXFileIO.write((u8*)"test_movie_last.rgb", rgb);
#endif
    Data* file = m.finish();
    ck((u8*)"after finish, nothing more is added", !m.add(picture(w, h, (i32)7)));
    ck((u8*)"the file is EBML, a webm, of VP8", file.length() > (i32)100 && file.byteAt((i32)0) == (u8)$1A && file.byteAt((i32)1) == (u8)$45 &&
                                               file.byteAt((i32)2) == (u8)$DF && file.byteAt((i32)3) == (u8)$A3 &&
                                               contains(file, (u8*)"webm") && contains(file, (u8*)"V_VP8"));
    // the segment's size (eight bytes after its ID) is the rest of the file
    i32 at = (i32)0;
    for (i32 i = (i32)0; i + (i32)4 < file.length() && at == (i32)0; i = i + (i32)1)
        {
        if (file.byteAt(i) == (u8)$18 && file.byteAt(i + (i32)1) == (u8)$53 && file.byteAt(i + (i32)2) == (u8)$80 && file.byteAt(i + (i32)3) == (u8)$67)
            {
            at = i + (i32)4;
            }
        }
    i64 segSize = (i64)0;
    for (i32 i = (i32)1; i < (i32)8; i = i + (i32)1)
        {
        segSize = (segSize << (i64)8) | (i64)file.byteAt(at + i);
        }
    ck((u8*)"the segment's size is the rest of the file", at > (i32)0 && file.byteAt(at) == (u8)$01 && segSize == (i64)(file.length() - at - (i32)8));

    // RGBA bytes and a UXImage of the same picture make the same movie
    UXMovie* a = UXMovie.make(w, h, (i32)25);
    UXMovie* b = UXMovie.make(w, h, (i32)25);
    UXImage* p = picture(w, h, (i32)2);
    a.add(p);
    b.addPixels(rgbaOf(p).bytes(), w, h, (i32)1);
    ck((u8*)"RGBA input and UXImage input make the same file", a.finish().equals(b.finish()));

#if MOVIE_FILES
    UXFileIO.write((u8*)"test_movie.webm", file);
#endif
    Stdio.printf("  webm %d bytes, checksum %u\n", file.length(), checksum(file));
    Stdio.printf(gFails == (i32)0 ? "PASS: UXMovie\n" : "FAIL: %d\n", gFails);
    }
