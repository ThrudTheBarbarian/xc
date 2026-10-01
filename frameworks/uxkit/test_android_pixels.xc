// test_android_pixels.xc — a bitmap region drawn in a drawRect on Android (drawPixels), read back as pixels.
//
// A client draws icons and a hero picture out of its texture atlas inside 2-D panels: a REGION of a
// bitmap, scaled, with an alpha.  Each check below catches one way that goes wrong: upside down (the
// classic -- an image drawn y-up into a y-down context), the wrong region, no scaling, an alpha that
// is ignored, and a byte layout read in the wrong order.  The same checks as mac-pixels, in the
// emulator, read back from the rig's offscreen Bitmap walk of the window.
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXImage.xc"

extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_render(i32 handle);
extern i32 ux_and_pixel(i32 x, i32 y);
extern void ux_and_quit(i32 rc);

// A 4x2 RGBA bitmap:  R R G G  /  B B Y Y
u8 gSheet[32];
void put(i32 i, i32 r, i32 g, i32 b)
    {
    gSheet[i * (i32)4] = (u8)r;
    gSheet[i * (i32)4 + (i32)1] = (u8)g;
    gSheet[i * (i32)4 + (i32)2] = (u8)b;
    gSheet[i * (i32)4 + (i32)3] = (u8)255;
    }
UXImage@ gImg;

// A view that paints far past its own frame, as a self-scrolling panel paints its page: the part
// outside its frame must not reach the window.
class Spill : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(UXGeom.make((i16)-10, (i16)-10, (i16)60, (i16)60), (i32)255, (i32)0, (i32)0);
        }
    }

class Board : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)255, (i32)255, (i32)255);
        // the whole sheet, 10x: each source pixel a 10x10 block
        g.drawPixels(&gSheet[(i32)0], (i32)4, (i32)2, (i32)UXPIX_RGBA, UXGeom.make((i16)0, (i16)0, (i16)4, (i16)2),
                     UXGeom.make((i16)10, (i16)10, (i16)40, (i16)20), (i32)255);
        // only the right half (G / Y), into a 20x20 square
        g.drawPixels(&gSheet[(i32)0], (i32)4, (i32)2, (i32)UXPIX_RGBA, UXGeom.make((i16)2, (i16)0, (i16)2, (i16)2),
                     UXGeom.make((i16)60, (i16)10, (i16)20, (i16)20), (i32)255);
        // the whole sheet at half alpha over white
        g.drawPixels(&gSheet[(i32)0], (i32)4, (i32)2, (i32)UXPIX_RGBA, UXGeom.make((i16)0, (i16)0, (i16)4, (i16)2),
                     UXGeom.make((i16)100, (i16)10, (i16)40, (i16)20), (i32)128);
        // REFERENCE SWATCHES: the toolkit's own fill of each colour.  The capture bitmap is in the
        // display's colour space, so a saturated sRGB colour reads back converted; a drawn pixel is
        // checked against the fill of the same colour, which has been through the same conversion.
        g.fillRectRGB(UXGeom.make((i16)60, (i16)40, (i16)8, (i16)8), (i32)255, (i32)0, (i32)0);
        g.fillRectRGB(UXGeom.make((i16)70, (i16)40, (i16)8, (i16)8), (i32)0, (i32)0, (i32)255);
        g.fillRectRGB(UXGeom.make((i16)80, (i16)40, (i16)8, (i16)8), (i32)0, (i32)200, (i32)0);
        g.fillRectRGB(UXGeom.make((i16)90, (i16)40, (i16)8, (i16)8), (i32)255, (i32)220, (i32)0);
        g.fillRectRGB(UXGeom.make((i16)100, (i16)40, (i16)8, (i16)8), (i32)255, (i32)0, (i32)255);
        g.fillRectRGB(UXGeom.make((i16)110, (i16)40, (i16)8, (i16)8), (i32)0, (i32)255, (i32)255);
        g.fillRectRGBA(UXGeom.make((i16)120, (i16)40, (i16)8, (i16)8), (i32)255, (i32)0, (i32)0, (i32)128);
        // a UXImage (0xAARRGGBB words): magenta | cyan
        gImg.drawIn(g, UXGeom.make((i16)0, (i16)0, (i16)2, (i16)1), UXGeom.make((i16)10, (i16)40, (i16)40, (i16)20), (i32)255);
        }
    }

i32 gFails;
void near(u8* what, i32 px, i32 r, i32 g, i32 b, i32 tol)
    {
    i32 pr = (px >> (i32)16) & (i32)255;
    i32 pg = (px >> (i32)8) & (i32)255;
    i32 pb = px & (i32)255;
    i32 dr = pr > r ? pr - r : r - pr;
    i32 dg = pg > g ? pg - g : g - pg;
    i32 db = pb > b ? pb - b : b - pb;
    if (dr <= tol && dg <= tol && db <= tol)
        {
        Stdio.printf("  ok   %s (%d,%d,%d)\n", what, pr, pg, pb);
        }
    else
        {
        Stdio.printf("  FAIL %s: got (%d,%d,%d), want (%d,%d,%d)\n", what, pr, pg, pb, r, g, b);
        gFails = gFails + (i32)1;
        }
    }

void same(u8* what, i32 px, i32 ref)
    {
    near(what, px, (ref >> (i32)16) & (i32)255, (ref >> (i32)8) & (i32)255, ref & (i32)255, (i32)6);
    }

void testBody(void)
    {
    gFails = (i32)0;
    put((i32)0, (i32)255, (i32)0, (i32)0);
    put((i32)1, (i32)255, (i32)0, (i32)0);
    put((i32)2, (i32)0, (i32)200, (i32)0);
    put((i32)3, (i32)0, (i32)200, (i32)0);
    put((i32)4, (i32)0, (i32)0, (i32)255);
    put((i32)5, (i32)0, (i32)0, (i32)255);
    put((i32)6, (i32)255, (i32)220, (i32)0);
    put((i32)7, (i32)255, (i32)220, (i32)0);
    gImg = UXImage.make((i32)2, (i32)1);
    gImg.setPixelRaw((i32)0, (i32)0, (u32)$FFFF00FF);
    gImg.setPixelRaw((i32)1, (i32)0, (u32)$FF00FFFF);

    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_and_quit((i32)1);
        return;
        }
    UXWindow* win = new UXWindow();
    Board* board = new Board();
    win.open((u8*)"Pixels", UXGeom.make((i16)80, (i16)80, (i16)160, (i16)80), board);
    board.addSubview(new Spill(), UXGeom.make((i16)135, (i16)55, (i16)15, (i16)15));
    win.displayAll();
    ux_and_render((i32)1);

    i32 red = ux_and_pixel((i32)64, (i32)44);
    i32 blue = ux_and_pixel((i32)74, (i32)44);
    i32 green = ux_and_pixel((i32)84, (i32)44);
    i32 yellow = ux_and_pixel((i32)94, (i32)44);
    i32 magenta = ux_and_pixel((i32)104, (i32)44);
    i32 cyan = ux_and_pixel((i32)114, (i32)44);
    i32 pink = ux_and_pixel((i32)124, (i32)44);
    same("top-left of the sheet is red (not upside down)", ux_and_pixel((i32)15, (i32)15), red);
    same("bottom-left is blue", ux_and_pixel((i32)15, (i32)25), blue);
    same("top-right is green", ux_and_pixel((i32)45, (i32)15), green);
    same("bottom-right is yellow", ux_and_pixel((i32)45, (i32)25), yellow);
    same("the sub-region starts at its own left (green, not red)", ux_and_pixel((i32)65, (i32)15), green);
    same("...and holds its bottom row (yellow)", ux_and_pixel((i32)75, (i32)25), yellow);
    same("alpha 128 red over white is the fill's pink", ux_and_pixel((i32)105, (i32)15), pink);
    same("a UXImage's left pixel is magenta (ARGB words read right)", ux_and_pixel((i32)15, (i32)50), magenta);
    same("...and its right one cyan", ux_and_pixel((i32)45, (i32)50), cyan);
    near("outside every draw it is still white", ux_and_pixel((i32)155, (i32)75), (i32)255, (i32)255, (i32)255, (i32)2);
    same("a view paints inside its frame", ux_and_pixel((i32)140, (i32)60), red);
    near("...and NOT past it (its drawing is clipped to its frame)", ux_and_pixel((i32)130, (i32)50), (i32)255, (i32)255, (i32)255, (i32)2);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: drawPixels on Android -- region, scale, alpha, both layouts, the right way up\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    ux_and_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run(); // posts to the UI thread -- never returns
    }
