// showcase_ios.xc — the iOS contact sheet: one window, every widget (real
// native overlays where they exist), ONE render and dump; capture.sh crops.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "showcase_widgets.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_render(i32 handle);
extern i32 ux_ios_dump_ppm(u8* path);
extern void ux_ios_quit(i32 rc);

void shoot(void)
    {
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"sheet", UXGeom.make(0, 60, 440, 300), content);
    buildSheet(content);
    win.tree.finalise();
    win.displayAll();
    ux_ios_render((i32)1);
    ux_ios_dump_ppm((u8*)"/tmp/ux-sheet.ppm");
    Stdio.printf("PASS: sheet shot\n");
    ux_ios_quit((i32)0);
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    ux_ios_set_entry((pointer)&shoot);
    ux_ios_shell_run();
    }
