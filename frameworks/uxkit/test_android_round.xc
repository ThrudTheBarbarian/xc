// test_android_round.xc — a rounded panel on Android, where the toolkit draws the scroll view (round_body.xc).
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"

extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_render(i32 handle);
extern i32 ux_and_pixel(i32 x, i32 y);
extern void ux_and_quit(i32 rc);
i32 roundPixel(i32 x, i32 y) { return ux_and_pixel(x, y); }
void roundRender(i32 h) { ux_and_render(h); }
i32 roundEdge(i32 h) { return roundPixel((i32)80, (i32)20); }
#define ROUND_BACKEND "Android"
#import "round_body.xc"

void testBody(void)
    {
    ux_and_quit(roundBody() == (i32)0 ? (i32)0 : (i32)1);
    }
void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
    }
