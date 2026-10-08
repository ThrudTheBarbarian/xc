// test_web_pixels.xc — a bitmap region drawn in a drawRect on the web backend (drawPixels).
//
// The same checks as mac-pixels and win32-pixels -- the right way up, the right region, scaled,
// alpha honoured, both byte layouts -- read back through the node rig, which records the draw with a
// copy of the region and replays it by nearest sampling.  The page's drawImage is the same call.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXImage.xc"

extern i32 ux_test_pixel(i32 h, i32 x, i32 y);

u8 gSheet[32]; // 4x2 RGBA:  R R G G  /  B B Y Y
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
        g.drawPixels(&gSheet[(i32)0], (i32)4, (i32)2, (i32)UXPIX_RGBA, UXGeom.make((i16)0, (i16)0, (i16)4, (i16)2),
                     UXGeom.make((i16)10, (i16)10, (i16)40, (i16)20), (i32)255);
        g.drawPixels(&gSheet[(i32)0], (i32)4, (i32)2, (i32)UXPIX_RGBA, UXGeom.make((i16)2, (i16)0, (i16)2, (i16)2),
                     UXGeom.make((i16)60, (i16)10, (i16)20, (i16)20), (i32)255);
        g.drawPixels(&gSheet[(i32)0], (i32)4, (i32)2, (i32)UXPIX_RGBA, UXGeom.make((i16)0, (i16)0, (i16)4, (i16)2),
                     UXGeom.make((i16)100, (i16)10, (i16)40, (i16)20), (i32)128);
        gImg.drawIn(g, UXGeom.make((i16)0, (i16)0, (i16)2, (i16)1), UXGeom.make((i16)10, (i16)40, (i16)40, (i16)20), (i32)255);
        }
    }

i32 gFails = 0;
void near(u8* what, i32 x, i32 y, i32 r, i32 g, i32 b)
    {
    i32 c = ux_test_pixel((i32)1, x, y);
    i32 pr = (c >> (i32)16) & (i32)255;
    i32 pg = (c >> (i32)8) & (i32)255;
    i32 pb = c & (i32)255;
    i32 dr = pr > r ? pr - r : r - pr;
    i32 dg = pg > g ? pg - g : g - pg;
    i32 db = pb > b ? pb - b : b - pb;
    if (c >= (i32)0 && dr <= (i32)3 && dg <= (i32)3 && db <= (i32)3)
        {
        Stdio.printf("  ok   %s (%d,%d,%d)\n", what, pr, pg, pb);
        }
    else
        {
        Stdio.printf("  FAIL %s: got (%d,%d,%d), want (%d,%d,%d)\n", what, pr, pg, pb, r, g, b);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
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
    UXWebDriver* wd = new UXWebDriver();
    gDriver = wd;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        return;
        }
    UXWindow* win = new UXWindow();
    Board* board = new Board();
    win.open((u8*)"Pixels", UXGeom.make((i16)80, (i16)80, (i16)160, (i16)80), board);
    board.addSubview(new Spill(), UXGeom.make((i16)135, (i16)55, (i16)15, (i16)15));
    win.displayAll();
    wd.webPresentAll();
    near("top-left of the sheet is red (not upside down)", (i32)15, (i32)15, (i32)255, (i32)0, (i32)0);
    near("bottom-left is blue", (i32)15, (i32)25, (i32)0, (i32)0, (i32)255);
    near("top-right is green", (i32)45, (i32)15, (i32)0, (i32)200, (i32)0);
    near("bottom-right is yellow", (i32)45, (i32)25, (i32)255, (i32)220, (i32)0);
    near("the sub-region starts at its own left (green)", (i32)65, (i32)15, (i32)0, (i32)200, (i32)0);
    near("...and holds its bottom row (yellow)", (i32)75, (i32)25, (i32)255, (i32)220, (i32)0);
    near("alpha 128 red over white is pink", (i32)105, (i32)15, (i32)255, (i32)127, (i32)127);
    near("a UXImage's left pixel is magenta", (i32)15, (i32)50, (i32)255, (i32)0, (i32)255);
    near("...and its right one cyan", (i32)45, (i32)50, (i32)0, (i32)255, (i32)255);
    near("a view paints inside its frame", (i32)140, (i32)62, (i32)255, (i32)0, (i32)0);
    near("...and NOT past it (its drawing is clipped to its frame)", (i32)130, (i32)50, (i32)255, (i32)255, (i32)255);
    // Re-render into the SAME buffer (same address and size), as a re-drawn view does: the loader
    // caches the bitmap by address, so it must revalidate or the page would keep the first frame.
    put((i32)0, (i32)0, (i32)0, (i32)0);
    put((i32)1, (i32)0, (i32)0, (i32)0);
    gImg.setPixelRaw((i32)0, (i32)0, (u32)0xFF000000);
    win.displayAll();
    wd.webPresentAll();
    near("a re-render into the same buffer shows (top-left now black)", (i32)15, (i32)15, (i32)0, (i32)0, (i32)0);
    near("a UXImage re-render shows too", (i32)15, (i32)50, (i32)0, (i32)0, (i32)0);
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: drawPixels on the web -- region, scale, alpha, both layouts, the right way up\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
