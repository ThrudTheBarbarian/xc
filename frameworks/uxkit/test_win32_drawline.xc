// test_win32_drawline.xc — verify UXGdiGraphics.drawLine draws a UNIFORM line (not a wedge heavier on the right).
// Renders a frame to an offscreen bitmap and reads pixels back with GetPixel.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXGdiGraphics.xc"
#import "UXGeometry.xc"
#import "UXWin32.h.xc"

i32 black(pointer dc, i32 x, i32 y)
    {
    return GetPixel(dc, x, y) == (u32)0 ? (i32)1 : (i32)0;
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
    pointer mdc = CreateCompatibleDC(wdc);
    pointer bmp = CreateCompatibleBitmap(wdc, (i32)140, (i32)60);
    SelectObject(mdc, bmp);
    RECT rc;
    rc.left = (i32)0;
    rc.top = (i32)0;
    rc.right = (i32)140;
    rc.bottom = (i32)60;
    pointer wbr = CreateSolidBrush((u32)$00FFFFFF);
    FillRect(mdc, (pointer)&rc, wbr);
    DeleteObject(wbr); // white

    UXGdiGraphics* g = new UXGdiGraphics();
    g.bind(mdc, UXGeom.zero());
    // a frame: top/bottom horizontal, left/right vertical (pen 1 = black)
    UXRect fr = UXGeom.make((i16)10, (i16)10, (i16)100, (i16)30);
    g.drawLine(fr.x, fr.y, (i16)(fr.x + fr.w), fr.y, (i32)1);
    g.drawLine(fr.x, (i16)(fr.y + fr.h), (i16)(fr.x + fr.w), (i16)(fr.y + fr.h), (i32)1);
    g.drawLine(fr.x, fr.y, fr.x, (i16)(fr.y + fr.h), (i32)1);
    g.drawLine((i16)(fr.x + fr.w), fr.y, (i16)(fr.x + fr.w), (i16)(fr.y + fr.h), (i32)1);

    // top edge should be black uniformly along its length (left, middle, right), at y=10 and y=11 (2px).
    Stdio.printf("top y10: L=%d M=%d R=%d\n", black(mdc, 15, 10), black(mdc, 60, 10), black(mdc, 105, 10));
    Stdio.printf("top y11: L=%d M=%d R=%d\n", black(mdc, 15, 11), black(mdc, 60, 11), black(mdc, 105, 11));
    // interior stays white (no wedge filling the box on the right)
    Stdio.printf("interior: TL=%d TR=%d\n", black(mdc, 20, 25), black(mdc, 100, 25));
    // left + right vertical edges present
    Stdio.printf("verticals: left=%d right=%d\n", black(mdc, 10, 25), black(mdc, 110, 25));
    Stdio.printf("done\n");
    DeleteDC(mdc);
    ReleaseDC((pointer)0, wdc);
    }
