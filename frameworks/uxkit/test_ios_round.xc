// test_ios_round.xc — a rounded panel on iOS, a UIScrollView rounded by its own layer (round_body.xc).
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_render(i32 handle);
extern i32 ux_ios_pixel(i32 x, i32 y);
extern void ux_ios_quit(i32 rc);
i32 roundPixel(i32 x, i32 y) { return ux_ios_pixel(x, y); }
void roundRender(i32 h) { ux_ios_render(h); }
i32 roundEdge(i32 h) { return roundPixel((i32)80, (i32)20); }
#define ROUND_BACKEND "iOS"
#import "round_body.xc"

void testBody(void)
    {
    ux_ios_quit(roundBody() == (i32)0 ? (i32)0 : (i32)1);
    }
void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
    }
