// test_segmented_android.xc — UXSegmentedControl on Android is native (the android-segmented gate):
// Android has no platform segmented control, so it is a row of native ToggleButtons.  The app logs
// where each segment it wants tapped is on the screen, and the GATE taps it for real (adb input
// tap).  Checked: the row's segments and labels; the selection the app made, shown; a real tap
// selecting that segment in the model, firing the action, and the row following; a selection the app
// makes shown natively; and in a multiple-selection control, real taps toggling segments on their own.
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXSegmentedControl.xc"

extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);
extern i32 ux_and_test_seg_count(i32 handle, i32 node);
extern i32 ux_and_test_seg_selected(i32 handle, i32 node);
extern i32 ux_and_test_seg_text_is(i32 handle, i32 node, i32 seg, u8* want);
extern void ux_and_test_seg_centre(i32 handle, i32 node, i32 seg, i32* x, i32* y);

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

i32 gFired;
class Target : Object
    {
    void picked(UXControl* sender)
        {
        gFired = gFired + (i32)1;
        }
    }

UXWindow* gWin;
UXSegmentedControl* gSeg;
UXSegmentedControl* gMulti;
Target* gTarget;
i32 gStep;
i32 gWaited;

// ask the gate to tap a segment: its centre on the screen, on a line of its own
void askTap(UXSegmentedControl* c, i32 seg, u8* tag)
    {
    i32 x = (i32)0;
    i32 y = (i32)0;
    ux_and_test_seg_centre(gWin.handle, (i32)c.index, seg, &x, &y);
    Stdio.printf("%s %d %d\n", tag, x, y);
    }

void finish(void)
    {
    ux_and_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void verdict(void)
    {
    Stdio.printf(gFails == (i32)0 ? "PASS: UXSegmentedControl on Android is a row of native ToggleButtons -- real taps select, the model and the row agree\n" : "FAIL: %d\n", gFails);
    ux_and_test_call_later((pointer)&finish, (i32)1000);
    }

// the steps, each waiting (polling) for the gate's tap to arrive
void step(void)
    {
    i32 h = gWin.handle;
    i32 sn = (i32)gSeg.index;
    i32 mn = (i32)gMulti.index;
    if (gStep == (i32)1)
        {
        if (gFired == (i32)0 && gWaited < (i32)100)
            {
            gWaited = gWaited + (i32)1;
            ux_and_test_call_later((pointer)&step, (i32)100);
            return;
            }
        ck((u8*)"a real tap on the third segment fires the action", gFired == (i32)1);
        ck((u8*)"...selects it in the model", gSeg.selectedSegment() == (i32)2);
        ck((u8*)"...and the row shows it alone", ux_and_test_seg_selected(h, sn) == (i32)2);
        gSeg.selectSegment((i32)1);
        gWin.displayAll();
        ck((u8*)"a selection the app makes is shown natively", ux_and_test_seg_selected(h, sn) == (i32)1);
        gStep = (i32)2;
        gWaited = (i32)0;
        askTap(gMulti, (i32)0, (u8*)"TAP2");
        ux_and_test_call_later((pointer)&step, (i32)100);
        return;
        }
    if (gStep == (i32)2)
        {
        if (gFired < (i32)2 && gWaited < (i32)100)
            {
            gWaited = gWaited + (i32)1;
            ux_and_test_call_later((pointer)&step, (i32)100);
            return;
            }
        gStep = (i32)3;
        gWaited = (i32)0;
        askTap(gMulti, (i32)2, (u8*)"TAP3");
        ux_and_test_call_later((pointer)&step, (i32)100);
        return;
        }
    if (gFired < (i32)3 && gWaited < (i32)100)
        {
        gWaited = gWaited + (i32)1;
        ux_and_test_call_later((pointer)&step, (i32)100);
        return;
        }
    ck((u8*)"in a multiple-selection control, real taps toggle segments on their own", gMulti.isSelected((i32)0) && !gMulti.isSelected((i32)1) && gMulti.isSelected((i32)2));
    ck((u8*)"...and the single-selection one is left as it was", gSeg.selectedSegment() == (i32)1);
    verdict();
    }

void start(void)
    {
    i32 h = gWin.handle;
    i32 sn = (i32)gSeg.index;
    ck((u8*)"the control is a native row of three", ux_and_test_seg_count(h, sn) == (i32)3);
    ck((u8*)"...labelled as the model is", ux_and_test_seg_text_is(h, sn, (i32)0, (u8*)"Map") != (i32)0 &&
                                         ux_and_test_seg_text_is(h, sn, (i32)1, (u8*)"Tech") != (i32)0 &&
                                         ux_and_test_seg_text_is(h, sn, (i32)2, (u8*)"Log") != (i32)0);
    ck((u8*)"...showing the selection the app made", ux_and_test_seg_selected(h, sn) == (i32)0);
    gStep = (i32)1;
    gWaited = (i32)0;
    askTap(gSeg, (i32)2, (u8*)"TAP1");
    ux_and_test_call_later((pointer)&step, (i32)100);
    }

void testBody(void)
    {
    gFails = (i32)0;
    gFired = (i32)0;
    ux_and_test_watchdog((i32)90000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    gWin = new UXWindow();
    UXView* root = new UXView();
    gWin.open((u8*)"segmented", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), root);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(gWin);
    gTarget = new Target();
    gSeg = new UXSegmentedControl();
    gSeg.addSegment((u8*)"Map", (i32)1);
    gSeg.addSegment((u8*)"Tech", (i32)2);
    gSeg.addSegment((u8*)"Log", (i32)3);
    gSeg.selectSegment((i32)0);
    gSeg.setAction(&gTarget.picked);
    root.addSubview(gSeg, UXGeom.make((i16)20, (i16)80, (i16)300, (i16)40));
    gMulti = new UXSegmentedControl();
    gMulti.setMultiSelect(true);
    gMulti.addSegment((u8*)"B", (i32)1);
    gMulti.addSegment((u8*)"I", (i32)2);
    gMulti.addSegment((u8*)"U", (i32)3);
    gMulti.setAction(&gTarget.picked);
    root.addSubview(gMulti, UXGeom.make((i16)20, (i16)160, (i16)180, (i16)40));
    gWin.displayAll();
    ux_and_test_call_later((pointer)&start, (i32)1500);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
    }
