// test_ios_radio.xc — iOS radio buttons, and native values following the model (the ios-radio gate).
// UIKit has no radio control, so a radio button is a button showing the system's circle symbols:
// checked here are that it is native, shows its selection, that a tap through UIKit's own
// target-action selects it (the group clearing the other, natively too), and that after a native
// control exists the app's changes to its model show in it -- a check box, a slider, a stepper and
// a progress bar.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXSlider.xc"
#import "UXStepper.xc"
#import "UXProgressBar.xc"
#import "Progress.xc"
#import "UXGeometry.xc"
extern i32 ux_ios_test_radio_state(i32 handle, i32 node);
extern i32 ux_ios_test_native_value(i32 handle, i32 node);
extern void ux_ios_post_click(i32 handle, i32 x, i32 y);
extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_call_later(pointer fn, i32 ms);

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
UXRadioButton* gA;
UXRadioButton* gB;
UXCheckbox* gCb;
UXSlider* gSl;
UXStepper* gSt;
UXProgressBar* gPg;
Progress* gProg;
Target* gT;
UXRadioGroup* gGrp; // the buttons hold their group weakly

void finish(void)
    {
    ux_ios_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void after(void)
    {
    i32 h = gWin.handle;
    ck((u8*)"a tap on the second radio button, through UIKit's target-action, selects it", gB.isSelected() && !gA.isSelected());
    ck((u8*)"...fires its action", gFired == (i32)1);
    ck((u8*)"...and both native buttons show it", ux_ios_test_radio_state(h, (i32)gB.index) == (i32)1 && ux_ios_test_radio_state(h, (i32)gA.index) == (i32)0);
    // the app changes the models of controls that already exist
    gCb.setChecked(true);
    gSl.setValue((i32)70);
    gSt.setValue((i32)4);
    gProg.setCompletedUnitCount((i64)((i32)3));
    gGrp.select(gA);
    gWin.displayAll();
    ck((u8*)"the app checking the box turns the switch on", ux_ios_test_native_value(h, (i32)gCb.index) == (i32)1);
    ck((u8*)"the app moving the slider moves the UISlider", ux_ios_test_native_value(h, (i32)gSl.index) == (i32)70);
    ck((u8*)"the app setting the stepper sets the UIStepper", ux_ios_test_native_value(h, (i32)gSt.index) == (i32)4);
    ck((u8*)"progress advancing advances the UIProgressView", ux_ios_test_native_value(h, (i32)gPg.index) == (i32)750);
    ck((u8*)"the app selecting the first radio shows natively", ux_ios_test_radio_state(h, (i32)gA.index) == (i32)1 && ux_ios_test_radio_state(h, (i32)gB.index) == (i32)0);
    Stdio.printf(gFails == (i32)0 ? "PASS: iOS radio buttons are native, and native controls follow their models\n" : "FAIL: %d\n", gFails);
    ux_ios_test_call_later((pointer)&finish, (i32)300);
    }
void checks(void)
    {
    i32 h = gWin.handle;
    ck((u8*)"the radio buttons are native", ux_ios_test_radio_state(h, (i32)gA.index) >= (i32)0 && ux_ios_test_radio_state(h, (i32)gB.index) >= (i32)0);
    ck((u8*)"...showing the selection the app made", ux_ios_test_radio_state(h, (i32)gA.index) == (i32)1 && ux_ios_test_radio_state(h, (i32)gB.index) == (i32)0);
    ck((u8*)"the controls start at their models' values", ux_ios_test_native_value(h, (i32)gCb.index) == (i32)0 && ux_ios_test_native_value(h, (i32)gSl.index) == (i32)20 && ux_ios_test_native_value(h, (i32)gPg.index) == (i32)250);
    ux_ios_post_click(h, (i32)60, (i32)102);
    ux_ios_test_call_later((pointer)&after, (i32)400);
    }

void testBody(void)
    {
    gFails = (i32)0;
    gFired = (i32)0;
    ux_ios_test_watchdog((i32)30000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    gWin = new UXWindow();
    UXView* root = new UXView();
    gWin.open((u8*)"radio", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), root);
    app.addWindow(gWin);
    gT = new Target();
    gGrp = new UXRadioGroup();
    gA = new UXRadioButton();
    gA.setTitle((u8*)"Left");
    gB = new UXRadioButton();
    gB.setTitle((u8*)"Right");
    gB.setAction(&gT.picked);
    root.addSubview(gA, UXGeom.make((i16)20, (i16)60, (i16)200, (i16)28));
    root.addSubview(gB, UXGeom.make((i16)20, (i16)88, (i16)200, (i16)28));
    gGrp.add(gA);
    gGrp.add(gB);
    gGrp.select(gA);
    gCb = new UXCheckbox();
    gCb.setTitle((u8*)"Wrap");
    root.addSubview(gCb, UXGeom.make((i16)20, (i16)130, (i16)200, (i16)32));
    gSl = new UXSlider();
    gSl.setRange((i32)0, (i32)100);
    gSl.setValue((i32)20);
    root.addSubview(gSl, UXGeom.make((i16)20, (i16)170, (i16)240, (i16)30));
    gSt = new UXStepper();
    root.addSubview(gSt, UXGeom.make((i16)20, (i16)210, (i16)120, (i16)32));
    gProg = new Progress();
    gProg.setTotalUnitCount((i64)((i32)4));
    gProg.setCompletedUnitCount((i64)((i32)1));
    gPg = new UXProgressBar();
    gPg.setProgress(gProg);
    root.addSubview(gPg, UXGeom.make((i16)20, (i16)250, (i16)240, (i16)20));
    gWin.displayAll();
    ux_ios_test_call_later((pointer)&checks, (i32)800);
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
    }
