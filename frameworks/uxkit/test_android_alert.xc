// test_android_alert.xc — modal alerts on the Android backend (the
// android-alert gate).
//
// alertRun is now a real AlertDialog behind a nested Looper.loop() (the
// classic Android sync-dialog shape; a listener unwinds the nested loop with
// a marker exception).  Headless determinism: ux_and_alert_auto arms a
// Handler timer that CANCELS the shown dialog, which lands as the LAST
// button — the cancel convention — proving the nested loop parks, resumes,
// and maps the result, unattended on the emulator.
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXAlert.xc"

extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_alert_auto(i32 ms, i32 shot);

void testBody(void)
    {
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_and_quit((i32)1);
        return;
        }

    UXAlert* two = new UXAlert();
    two.addLine((u8*)"Discard changes?");
    two.addButton((u8*)"Keep");
    two.addButton((u8*)"Discard");
    ux_and_alert_auto((i32)400, (i32)0);
    i32 a = two.runModal();
    Stdio.printf("2-button auto-cancel -> %d (expect 2)\n", (i16)a);

    UXAlert* three = new UXAlert();
    three.icon = (i32)3;
    three.addLine((u8*)"Save changes?");
    three.addButton((u8*)"Save");
    three.addButton((u8*)"Discard");
    three.addButton((u8*)"Cancel");
    ux_and_alert_auto((i32)400, (i32)0);
    i32 b = three.runModal();
    Stdio.printf("3-button auto-cancel -> %d (expect 3)\n", (i16)b);

    bool pass = a == (i32)2 && b == (i32)3;
    Stdio.printf(pass ? "PASS: the nested-loop alert parks, resumes, and maps cancel on Android\n"
                      : "FAIL: 1\n");
    ux_and_quit(pass ? (i32)0 : (i32)1);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run(); // posts to the UI thread — never returns
    }
