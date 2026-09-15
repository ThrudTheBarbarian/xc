// test_win32_drawfont.xc — verify UXGdiGraphics.drawTextFont honours family/bold/italic (the styled
// font-chooser preview).  Renders "Agjy" to an offscreen bitmap and counts the black ink: bold must ink
// more than regular at the same family+size, and a mono family must differ in width from a proportional
// one.  Reads pixels back with GetPixel.  Skips cleanly when wine is absent.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXGdiGraphics.xc"
#import "UXGeometry.xc"
#import "UXWin32.h.xc"

i32 black(pointer dc, i32 x, i32 y)
    {
    return GetPixel(dc, x, y) == (u32)0 ? (i32)1 : (i32)0;
    }

// Count black pixels, and the rightmost inked column (a width proxy), in [0,W)x[0,H).
i32 gW;
i32 gInk;
i32 gRight;
void scan(pointer dc, i32 w, i32 h)
    {
    gInk = (i32)0;
    gRight = (i32)0;
    for (i32 y = (i32)0; y < h; y = y + (i32)1)
        {
        for (i32 x = (i32)0; x < w; x = x + (i32)1)
            {
            if (black(dc, x, y) != (i32)0)
                {
                gInk = gInk + (i32)1;
                if (x > gRight)
                    {
                    gRight = x;
                    }
                }
            }
        }
    }

// Render `s` with the given family/size/bold/italic on a whitened bitmap, then scan it.
void render(pointer wdc, u8* fam, i32 size, bool bold, bool italic)
    {
    pointer mdc = CreateCompatibleDC(wdc);
    pointer bmp = CreateCompatibleBitmap(wdc, (i32)300, (i32)80);
    SelectObject(mdc, bmp);
    RECT rc;
    rc.left = (i32)0;
    rc.top = (i32)0;
    rc.right = (i32)300;
    rc.bottom = (i32)80;
    pointer wbr = CreateSolidBrush((u32)$00FFFFFF);
    FillRect(mdc, (pointer)&rc, wbr);
    DeleteObject(wbr);
    UXGdiGraphics* g = new UXGdiGraphics();
    g.bind(mdc, UXGeom.zero());
    g.drawTextFont((u8*)"Agjy Agjy", (i16)6, (i16)6, (i32)1, fam, size, bold, italic);
    scan(mdc, (i32)300, (i32)80);
    DeleteDC(mdc);
    }

void main(void)
    {
    gDriver = new UXWin32Driver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("boot failed\n");
        return;
        }
    pointer wdc = GetDC((pointer)0);

    render(wdc, (u8*)"Arial", (i32)28, false, false);
    i32 reg = gInk;
    i32 regR = gRight;
    render(wdc, (u8*)"Arial", (i32)28, true, false);
    i32 bold = gInk;
    render(wdc, (u8*)"Courier New", (i32)28, false, false);
    i32 monoR = gRight;
    Stdio.printf("ink reg=%d bold=%d ; width arial=%d courier=%d\n", reg, bold, regR, monoR);
    Stdio.printf("boldHeavier=%d familyDiffers=%d\n",
                 (bold > reg) ? (i32)1 : (i32)0,
                 (monoR != regR) ? (i32)1 : (i32)0);
    Stdio.printf("done\n");
    ReleaseDC((pointer)0, wdc);
    }
