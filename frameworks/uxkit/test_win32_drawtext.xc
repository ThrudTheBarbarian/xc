// test_win32_drawtext.xc — verify UXGdiGraphics.drawText honours its `size` argument (the font-chooser
// preview).  Renders the same string at two sizes into an offscreen bitmap and reads the inked height
// back with GetPixel: bigger size must ink a taller region.  size 0 must match the default UI font.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXGdiGraphics.xc"
#import "UXGeometry.xc"
#import "UXWin32.h.xc"

i32 black(pointer dc, i32 x, i32 y)
    {
    return GetPixel(dc, x, y) == (u32)0 ? (i32)1 : (i32)0;
    }

// Height (in px) of the black ink within [x0,x1) x [y0,y1).
i32 inkHeight(pointer dc, i32 x0, i32 x1, i32 y0, i32 y1)
    {
    i32 top = (i32)-1;
    i32 bot = (i32)-1;
    for (i32 y = y0; y < y1; y = y + (i32)1)
        {
        i32 any = (i32)0;
        for (i32 x = x0; x < x1; x = x + (i32)1)
            {
            if (black(dc, x, y) != (i32)0)
                {
                any = (i32)1;
                y = y;
                x = x1;
                }
            }
        if (any != (i32)0)
            {
            if (top < (i32)0)
                {
                top = y;
                }
            bot = y;
            }
        }
    return top < (i32)0 ? (i32)0 : bot - top + (i32)1;
    }

// Render `s` at `size` on a freshly-whitened bitmap, return the inked height.
i32 measure(pointer wdc, i32 size)
    {
    pointer mdc = CreateCompatibleDC(wdc);
    pointer bmp = CreateCompatibleBitmap(wdc, (i32)200, (i32)100);
    SelectObject(mdc, bmp);
    RECT rc;
    rc.left = (i32)0;
    rc.top = (i32)0;
    rc.right = (i32)200;
    rc.bottom = (i32)100;
    pointer wbr = CreateSolidBrush((u32)$00FFFFFF);
    FillRect(mdc, (pointer)&rc, wbr);
    DeleteObject(wbr);

    UXGdiGraphics* g = new UXGdiGraphics();
    g.bind(mdc, UXGeom.zero());
    g.drawText((u8*)"Agjy", (i16)6, (i16)6, (i32)1, size); // ascenders + descenders → full em height

    i32 h = inkHeight(mdc, (i32)0, (i32)200, (i32)0, (i32)100);
    DeleteDC(mdc);
    return h;
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

    i32 h0 = measure(wdc, (i32)0); // default UI font
    i32 h12 = measure(wdc, (i32)12);
    i32 h40 = measure(wdc, (i32)40);
    Stdio.printf("ink h0=%d h12=%d h40=%d\n", h0, h12, h40);
    // The preview scales: 40px inks clearly taller than 12px (allow font-metric slack, expect > 2x).
    Stdio.printf("scales=%d\n", (h40 > h12 * (i32)2) ? (i32)1 : (i32)0);
    Stdio.printf("done\n");
    ReleaseDC((pointer)0, wdc);
    }
