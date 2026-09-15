// showcase_android2.xc — SHEET 2 (containers + navigation) of the Android contact sheet: one window, every widget
// (real native overlays where they exist), ONE render and dump; capture.sh
// crops.  Unlike iOS, boot() must run UI-side (JNI + setContentView), so it
// lives in shoot(), inside the posted entry.
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "showcase_widgets.xc"

extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_render(i32 handle);
extern i32 ux_and_dump_ppm(u8* name);
extern void ux_and_quit(i32 rc);

void shoot(void)
    {
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_and_quit((i32)1);
        return;
        }
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"sheet", UXGeom.make(0, 60, 440, 630), content);
    buildSheet2(content);
    win.tree.finalise();
    win.displayAll();
    ux_and_render((i32)1);
    ux_and_dump_ppm((u8*)"ux-sheet2.ppm");
    Stdio.printf("PASS: sheet shot\n");
    ux_and_quit((i32)0);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&shoot);
    ux_and_shell_run();
    }
