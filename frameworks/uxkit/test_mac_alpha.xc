// test_mac_alpha.xc — the RGBA family rendered for real on AppKit and read back as pixels.
//
// The RGB family was opaque everywhere: a layer that wanted a coastline at 0.92 or a border glow at
// 0.12 could not draw it, and on AppKit every NSColor said alpha:1.0.  This proves the fourth
// component is honoured, and it is measured rather than eyeballed: a shape at alpha 128 over white
// must come back mid-grey, at 64 lighter still, and at 255 exactly the colour.  Without the change
// every one of those rectangles is solid black, which is what the checks below reject.
//
// Headless and deterministic, like test_appkit_real: force one paint, read pixels back.  No window.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXShapePath.xc"
#import "UXPainter.xc"

i32 ux_ak_pixel(i32 handle, i32 x, i32 y); // shim: readback from the last force-painted bitmap
i32 ux_ak_pixel_alpha(i32 handle, i32 x, i32 y); // ...the alpha alone (a cleared pixel reads 0,0,0 white)
i32 ux_ak_dump_ppm(u8* path);

// The board is the whole window content, so a readback at (x,y) is the board's (x,y).
class InkBoard : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)255, (i32)255, (i32)255);
        // black at 1/2, at 1/4, and opaque: three greys the blend has to keep apart
        g.fillRectRGBA(UXGeom.make((i16)10, (i16)10, (i16)80, (i16)40), (i32)0, (i32)0, (i32)0, (i32)128);
        g.fillRectRGBA(UXGeom.make((i16)110, (i16)10, (i16)80, (i16)40), (i32)0, (i32)0, (i32)0, (i32)255);
        g.fillRectRGBA(UXGeom.make((i16)10, (i16)60, (i16)80, (i16)40), (i32)0, (i32)0, (i32)0, (i32)64);
        // a translucent FILLED POLYGON — the general primitive the ink's shapes are built from
        i16 tri[6];
        tri[0] = (i16)150;
        tri[1] = (i16)60;
        tri[2] = (i16)190;
        tri[3] = (i16)100;
        tri[4] = (i16)110;
        tri[5] = (i16)100;
        g.fillPolygonRGBA(&tri[0], (i32)3, (i32)200, (i32)0, (i32)0, (i32)128);
        // a translucent NATIVE STROKE — the path the map's ink takes (856 of 1805 calls are strokes)
        UXShapePath* line = new UXShapePath();
        line.moveTo((i16)10, (i16)112);
        line.lineTo((i16)190, (i16)112);
        UXPainter.strokePath(g, line, (i16)8, UXPainter.rgba((i32)0, (i32)0, (i32)255, (i32)200));
        // A CLEAR over an opaque fill: two identical black rectangles, one of them emptied afterwards.
        // A source-over fill at alpha 0 could not do this — it would leave the black in place.
        g.fillRectRGBA(UXGeom.make((i16)10, (i16)130, (i16)60, (i16)24), (i32)0, (i32)0, (i32)0, (i32)255);
        g.clearRect(UXGeom.make((i16)10, (i16)130, (i16)60, (i16)24));
        g.fillRectRGBA(UXGeom.make((i16)90, (i16)130, (i16)60, (i16)24), (i32)0, (i32)0, (i32)0, (i32)255);
        }
    }

i32 gFails;
void checkTrue(u8* what, bool cond)
    {
    if (cond)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }
i32 rr(i32 px)
    {
    return (px >> (i32)16) & (i32)255;
    }
i32 gg(i32 px)
    {
    return (px >> (i32)8) & (i32)255;
    }
i32 bb(i32 px)
    {
    return px & (i32)255;
    }

void main(void)
    {
    gFails = (i32)0;
    gDriver = new UXAppKitDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        return;
        }
    UXWindow* win = new UXWindow();
    InkBoard* board = new InkBoard();
    win.open((u8*)"Alpha", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)170), board);
    win.displayAll();
    ux_ak_dump_ppm((u8*)"/tmp/ux_alpha_check.ppm"); // a frame to look at, not just numbers

    i32 opaque = ux_ak_pixel((i32)1, (i32)150, (i32)30); // alpha 255 black -> black
    i32 half = ux_ak_pixel((i32)1, (i32)50, (i32)30);    // alpha 128 black over white -> mid grey
    i32 quarter = ux_ak_pixel((i32)1, (i32)50, (i32)80); // alpha 64  black over white -> light grey
    i32 tri = ux_ak_pixel((i32)1, (i32)150, (i32)92);    // red 200 @128 over white
    i32 stroke = ux_ak_pixel((i32)1, (i32)100, (i32)112); // blue @200 over white
    Stdio.printf("opaque=%d,%d,%d  half=%d,%d,%d  quarter=%d,%d,%d\n",
                 rr(opaque), gg(opaque), bb(opaque), rr(half), gg(half), bb(half),
                 rr(quarter), gg(quarter), bb(quarter));
    Stdio.printf("tri=%d,%d,%d  stroke=%d,%d,%d\n",
                 rr(tri), gg(tri), bb(tri), rr(stroke), gg(stroke), bb(stroke));

    // opaque first: the RGB path is unchanged, so alpha 255 is still the colour itself
    checkTrue("alpha 255 is opaque black", rr(opaque) < (i32)24 && gg(opaque) < (i32)24 && bb(opaque) < (i32)24);
    // the blend: 128 over white is mid grey — neither the colour (0) nor the background (255)
    checkTrue("alpha 128 over white is mid grey", rr(half) > (i32)95 && rr(half) < (i32)160);
    checkTrue("...and grey, not tinted", (rr(half) - gg(half) < (i32)10) && (gg(half) - bb(half) < (i32)10));
    // the value is used: a quarter alpha is half as dark again
    checkTrue("alpha 64 is lighter than alpha 128", rr(quarter) > rr(half) + (i32)25);
    checkTrue("...but still darker than the white background", rr(quarter) < (i32)225);
    // a filled polygon carries alpha too
    checkTrue("a translucent polygon blends its colour", rr(tri) > (i32)190 && gg(tri) < (i32)175 && bb(tri) < (i32)175);
    // and so does the native stroke the ink actually uses
    checkTrue("a translucent native stroke blends", bb(stroke) > (i32)200 && rr(stroke) < (i32)130);

    // THE CLEAR.  Two identical opaque blacks; the first was cleared afterwards.  Through ux_ak_pixel
    // both read 0,0,0, so the alpha is what tells them apart: cleared carries nothing (alpha 0), the
    // untouched one is still solid (alpha 255).  A source-over fill at alpha 0 would pass the first
    // and fail the second — it paints nothing and leaves the black behind.
    i32 cleared = ux_ak_pixel_alpha((i32)1, (i32)40, (i32)142);
    i32 solid = ux_ak_pixel_alpha((i32)1, (i32)120, (i32)142);
    Stdio.printf("clear alpha=%d solid alpha=%d\n", cleared, solid);
    checkTrue("a cleared rect carries nothing", cleared == (i32)0);
    checkTrue("...and its twin is still opaque", solid == (i32)255);

    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the RGBA family blends on AppKit — fill, polygon, native stroke and clear\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
