// test_android_values.xc — Android's native controls follow their models (the android-values gate).
// Once a native control exists, the app's changes to its model show in it on the next display: a
// check box, a slider, a progress bar and a popup.  A popup's new selection is not reported back
// as a pick (a Spinner reports programmatic selections too): its action does not fire.
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXControl.xc"
#import "UXSlider.xc"
#import "UXProgressBar.xc"
#import "UXProgress.xc"
#import "UXPopUpButton.xc"

extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);
extern i32 ux_and_test_native_value(i32 handle, i32 node);

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
UXCheckbox* gCb;
UXSlider* gSl;
UXProgress* gProg;
UXProgressBar* gPg;
UXPopUpButton* gPop;
Target* gT;

void finish(void)
    {
    ux_and_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void settled(void)
    {
    ck((u8*)"...and the new selection is not reported back as a pick", gFired == (i32)0);
    Stdio.printf(gFails == (i32)0 ? "PASS: Android's native controls follow their models\n" : "FAIL: %d\n", gFails);
    ux_and_test_call_later((pointer)&finish, (i32)500);
    }
void changed(void)
    {
    i32 h = gWin.handle;
    ck((u8*)"the app checking the box checks the CheckBox", ux_and_test_native_value(h, (i32)gCb.index) == (i32)1);
    ck((u8*)"the app moving the slider moves the SeekBar", ux_and_test_native_value(h, (i32)gSl.index) == (i32)70);
    ck((u8*)"progress advancing advances the ProgressBar", ux_and_test_native_value(h, (i32)gPg.index) == (i32)750);
    ck((u8*)"the app selecting an item selects it in the Spinner", ux_and_test_native_value(h, (i32)gPop.index) == (i32)2);
    ux_and_test_call_later((pointer)&settled, (i32)1200);
    }
void start(void)
    {
    i32 h = gWin.handle;
    ck((u8*)"the controls start at their models' values", ux_and_test_native_value(h, (i32)gCb.index) == (i32)0 &&
                                                          ux_and_test_native_value(h, (i32)gSl.index) == (i32)20 &&
                                                          ux_and_test_native_value(h, (i32)gPg.index) == (i32)250 &&
                                                          ux_and_test_native_value(h, (i32)gPop.index) == (i32)0);
    gFired = (i32)0;
    gCb.setChecked(true);
    gSl.setValue((i32)70);
    gProg.setCompleted((i32)3);
    gPop.selectItem((i32)2);
    gWin.displayAll();
    ux_and_test_call_later((pointer)&changed, (i32)500);
    }
void testBody(void)
    {
    gFails = (i32)0;
    gFired = (i32)0;
    ux_and_test_watchdog((i32)60000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    gWin = new UXWindow();
    UXView* root = new UXView();
    gWin.open((u8*)"values", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), root);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(gWin);
    gT = new Target();
    gCb = new UXCheckbox();
    gCb.setTitle((u8*)"Wrap");
    root.addSubview(gCb, UXGeom.make((i16)20, (i16)80, (i16)200, (i16)40));
    gSl = new UXSlider();
    gSl.setRange((i32)0, (i32)100);
    gSl.setValue((i32)20);
    root.addSubview(gSl, UXGeom.make((i16)20, (i16)130, (i16)240, (i16)40));
    gProg = new UXProgress();
    gProg.setTotal((i32)4);
    gProg.setCompleted((i32)1);
    gPg = new UXProgressBar();
    gPg.setProgress(gProg);
    root.addSubview(gPg, UXGeom.make((i16)20, (i16)180, (i16)240, (i16)20));
    gPop = new UXPopUpButton();
    gPop.addItem((u8*)"One", (i32)1);
    gPop.addItem((u8*)"Two", (i32)2);
    gPop.addItem((u8*)"Three", (i32)3);
    gPop.selectItem((i32)0);
    gPop.setAction(&gT.picked);
    root.addSubview(gPop, UXGeom.make((i16)20, (i16)210, (i16)200, (i16)48));
    gWin.displayAll();
    ux_and_test_call_later((pointer)&start, (i32)1500);
    }
void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
    }
