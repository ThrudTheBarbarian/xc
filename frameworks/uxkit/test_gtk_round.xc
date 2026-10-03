// test_gtk_round.xc — a rounded panel on GTK, where a scroll view is a GtkScrolledWindow.
//
// A 16px-rounded scroll view with a dark 1px edge over a white window, its document solid red and tall
// enough to need the bar.  The container's own CSS rounds it (a radius, a border, its overflow
// hidden), so the picture is read back from the real widgets, through UXWindow.snapshot: the corner
// is CUT (white just inside the frame's corner), the edge is drawn, the content is inside it, and
// nothing is drawn past the panel.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
extern i32 ux_gtk_test_scroll_native(i32 handle, i32 node);
void ux_gtk_wait_allocated(i32 handle);

class RoundBoard : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)255, (i32)255, (i32)255);
        }
    }
class RoundDoc : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)230, (i32)20, (i32)20);
        }
    }

i32 gFails;
UXImage* gShot;
i32 px(i32 x, i32 y)
    {
    return (i32)(gShot.px[y * gShot.w + x] & (u32)$FFFFFF);
    }
void rck(bool ok, u8* what, i32 v)
    {
    Stdio.printf("  %s %s (%06x)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, v);
    if (!ok)
        {
        gFails = gFails + (i32)1;
        }
    }
bool isWhite(i32 c) { return ((c >> (i32)16) & (i32)255) > (i32)235 && ((c >> (i32)8) & (i32)255) > (i32)235 && (c & (i32)255) > (i32)235; }
bool isRed(i32 c) { return ((c >> (i32)16) & (i32)255) > (i32)200 && ((c >> (i32)8) & (i32)255) < (i32)70; }
bool isDark(i32 c) { return ((c >> (i32)16) & (i32)255) < (i32)140 && ((c >> (i32)8) & (i32)255) < (i32)140; }

void main(void)
    {
    gDriver = new UXGtkDriver();
    gFails = (i32)0;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display\n");
        return;
        }
    UXWindow* win = new UXWindow();
    RoundBoard* board = new RoundBoard();
    win.open((u8*)"Round", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)140), board);
    UXScrollView* sv = new UXScrollView();
    sv.setCornerRadius((i32)16);
    sv.setBorderRGB((i32)60, (i32)60, (i32)60);
    board.addSubview(sv, UXGeom.make((i16)20, (i16)20, (i16)140, (i16)90));
    sv.document().addSubview(new RoundDoc(), UXGeom.make((i16)0, (i16)0, (i16)200, (i16)400));
    sv.setDocumentHeight((i32)400); // taller than the panel: the bar is shown
    win.displayAll();
    ux_gtk_wait_allocated(win.handle);
    rck(ux_gtk_test_scroll_native(win.handle, (i32)sv.index) != (i32)0, "the scroll view is a GtkScrolledWindow", (i32)0);
    gShot = win.snapshot((UXRect*)0);
    if (gShot == (UXImage*)0)
        {
        Stdio.printf("FAIL: no snapshot\n");
        return;
        }
    i32 corner = px((i32)22, (i32)22);
    rck(isWhite(corner), "the corner is cut: white just inside the frame's corner", corner);
    i32 edge = px((i32)80, (i32)20);
    rck(isDark(edge), "the edge is drawn along the top", edge);
    i32 inner = px((i32)60, (i32)60);
    rck(isRed(inner), "the content fills the inside", inner);
    i32 below = px((i32)80, (i32)112);
    rck(isWhite(below), "nothing past the panel's bottom", below);
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: a rounded panel on GTK -- a GtkScrolledWindow, corner cut, edge drawn, content inside\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
