// test_android_shield.xc — the input shield on Android (the android-shield gate), with REAL input:
// the app logs where its button is on the screen (TAP<n> x y) and the gate taps it with adb input.
// With a UXShieldView over the button, the tap reaches the shield, in the window's content
// coordinates, and the button does not fire; with the shield hidden, the same tap fires the button.
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"

extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);
extern void ux_and_test_node_centre(i32 handle, i32 node, i32* x, i32* y);

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
    void pressed(UXControl* sender)
        {
        gFired = gFired + (i32)1;
        }
    }
class Canvas : UXShieldView
    {
    i32 presses;
    i32 lastX;
    i32 lastY;
    void mouseDown(UXEvent* e)
        {
        presses = presses + (i32)1;
        lastX = (i32)e.x;
        lastY = (i32)e.y;
        }
    }

UXWindow* gWin;
UXButton* gBtn;
Canvas* gCanvas;
Target* gT;
i32 gStep;
i32 gWaited;

void finish(void)
    {
    ux_and_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void askTap(u8* tag)
    {
    i32 x = (i32)0;
    i32 y = (i32)0;
    ux_and_test_node_centre(gWin.handle, (i32)gBtn.index, &x, &y);
    Stdio.printf("%s %d %d\n", tag, x, y);
    }
void step(void)
    {
    if (gStep == (i32)1)
        {
        if (gCanvas.presses == (i32)0 && gFired == (i32)0 && gWaited < (i32)100)
            {
            gWaited = gWaited + (i32)1;
            ux_and_test_call_later((pointer)&step, (i32)100);
            return;
            }
        ck((u8*)"a real tap on the button, under the shield, reaches the shield", gCanvas.presses >= (i32)1);
        // the button's centre: 40 + 120/2, 120 + 48/2 in the window's content
        Stdio.printf("  (the shield heard %d, %d)\n", gCanvas.lastX, gCanvas.lastY);
        ck((u8*)"...at the button's place in the window's content coordinates", gCanvas.lastX >= (i32)97 && gCanvas.lastX <= (i32)103 && gCanvas.lastY >= (i32)141 && gCanvas.lastY <= (i32)147);
        ck((u8*)"...and the button under it does not fire", gFired == (i32)0);
        gCanvas.setHidden(true);
        gWin.displayAll();
        gStep = (i32)2;
        gWaited = (i32)0;
        askTap((u8*)"TAP2");
        ux_and_test_call_later((pointer)&step, (i32)100);
        return;
        }
    if (gFired == (i32)0 && gWaited < (i32)100)
        {
        gWaited = gWaited + (i32)1;
        ux_and_test_call_later((pointer)&step, (i32)100);
        return;
        }
    ck((u8*)"with the shield hidden, the same real tap fires the button", gFired == (i32)1);
    ck((u8*)"...and the hidden shield hears nothing", gCanvas.presses == (i32)1);
    Stdio.printf(gFails == (i32)0 ? "PASS: the Android input shield takes the real touch a control would have, in content coordinates\n" : "FAIL: %d\n", gFails);
    ux_and_test_call_later((pointer)&finish, (i32)1000);
    }
void start(void)
    {
    gStep = (i32)1;
    gWaited = (i32)0;
    askTap((u8*)"TAP1");
    ux_and_test_call_later((pointer)&step, (i32)100);
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
    gWin.open((u8*)"shield", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), root);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(gWin);
    gT = new Target();
    gBtn = new UXButton();
    gBtn.setTitle((u8*)"Press");
    gBtn.setAction(&gT.pressed);
    root.addSubview(gBtn, UXGeom.make((i16)40, (i16)120, (i16)120, (i16)48));
    gCanvas = new Canvas();
    root.addSubview(gCanvas, UXGeom.make((i16)0, (i16)0, (i16)300, (i16)400));
    gWin.displayAll();
    ux_and_test_call_later((pointer)&start, (i32)1500);
    }
void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
    }
