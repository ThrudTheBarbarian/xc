// test_ios_alert.xc — modal alerts on the iOS backend (the ios-alert gate).
//
// alertRun is now a real UIAlertController behind a nested CFRunLoop (the
// sync-modal shape).  Headless determinism: ux_ios_alert_auto arms an
// auto-dismiss that lands as the LAST button — the cancel convention — which
// proves the nested loop parks the caller, resumes it, and maps the result,
// unattended in the simulator.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXAlert.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_alert_auto(i32 ms, i32 shot);

void testBody(void)
    {
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_ios_quit((i32)1);
        return;
        }

    UXAlert* two = new UXAlert();
    two.addLine((u8*)"Discard changes?");
    two.addButton((u8*)"Keep");
    two.addButton((u8*)"Discard");
    ux_ios_alert_auto((i32)300, (i32)0);
    i32 a = two.runModal();
    Stdio.printf("2-button auto-dismiss -> %d (expect 2)\n", (i16)a);

    UXAlert* three = new UXAlert();
    three.icon = (i32)3;
    three.addLine((u8*)"Save changes?");
    three.addButton((u8*)"Save");
    three.addButton((u8*)"Discard");
    three.addButton((u8*)"Cancel");
    ux_ios_alert_auto((i32)300, (i32)0);
    i32 b = three.runModal();
    Stdio.printf("3-button auto-dismiss -> %d (expect 3)\n", (i16)b);

    bool pass = a == (i32)2 && b == (i32)3;
    Stdio.printf(pass ? "PASS: the nested-loop alert parks, resumes, and maps cancel on iOS\n"
                      : "FAIL: 1\n");
    ux_ios_quit(pass ? (i32)0 : (i32)1);
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run(); // UIApplicationMain — never returns
    }
