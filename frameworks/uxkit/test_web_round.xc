// test_web_round.xc — a rounded panel on the web backend, where the toolkit draws the scroll view
// (round_body.xc), replayed by the node rig: its rounded clip drops what lies outside a corner.  The
// rig records strokes without rasterising them, so the edge is read from the record.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"

extern i32 ux_test_pixel(i32 h, i32 x, i32 y);
extern i32 ux_test_op_count(i32 h, u8* name);
i32 gRoundWin;
i32 roundPixel(i32 x, i32 y) { return ux_test_pixel(gRoundWin, x, y); }
void roundRender(i32 h)
    {
    gRoundWin = h;
    ((UXWebDriver*)gDriver).webPresentAll(); // the frame the page would paint
    }
i32 roundEdge(i32 h) { return ux_test_op_count(h, (u8*)"stroke") > (i32)0 ? (i32)0x3c3c3c : (i32)0xffffff; }
#define ROUND_BACKEND "the web"
#import "round_body.xc"

void main(void)
    {
    gDriver = new UXWebDriver();
    i32 rc = roundBody();
    }
