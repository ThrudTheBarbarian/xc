// test_gtk_round.xc — a rounded panel on GTK, where the toolkit draws the scroll view.
//
// A 16px-rounded scroll view with a dark 1px edge over a white window, its document solid red and tall
// enough to need the bar.  Read back as pixels: the corner is CUT (white just inside the frame's
// corner), the edge is drawn, the content is inside it, and the bar is inset between the corners.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"

extern void ux_gtk_render(i32 handle);
extern i32 ux_gtk_pixel(i32 x, i32 y);
i32 roundPixel(i32 x, i32 y) { return ux_gtk_pixel(x, y); }
void roundRender(i32 h) { ux_gtk_render(h); }
i32 roundEdge(i32 h) { return roundPixel((i32)80, (i32)20); }
#define ROUND_BACKEND "GTK"
#import "round_body.xc"

void main(void)
    {
    gDriver = new UXGtkDriver();
    i32 rc = roundBody();
    }
