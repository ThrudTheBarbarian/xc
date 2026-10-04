// test_ios_shield.xc — the input shield on iOS (the ios-shield gate).  A UXShieldView over a real
// UIButton: UIKit's own hit test (the routing step a touch goes through; the simulator has no
// touch injection) finds the button before the shield exists and the shield once it does; a touch
// there reaches the shield in the window's content coordinates and does not fire the button; and a
// hidden shield stops shielding.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
extern i32 ux_ios_test_shield_tap(i32 handle, i32 x, i32 y);
extern i32 ux_ios_test_hit_kind(i32 handle, i32 x, i32 y);
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
    void pressed(UXControl* sender)
        {
        gFired = gFired + (i32)1;
        }
    }
// the design surface: it records where a press lands
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

void finish(void)
    {
    ux_ios_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void hidden(void)
    {
    i32 h = gWin.handle;
    ck((u8*)"hidden, the shield stops shielding: UIKit finds the button again", ux_ios_test_hit_kind(h, (i32)90, (i32)114) == (i32)1);
    Stdio.printf(gFails == (i32)0 ? "PASS: the iOS input shield takes the touch a control would have, in content coordinates\n" : "FAIL: %d\n", gFails);
    ux_ios_test_call_later((pointer)&finish, (i32)300);
    }
void shielded(void)
    {
    i32 h = gWin.handle;
    ck((u8*)"with the shield over it, UIKit's hit test finds the shield", ux_ios_test_hit_kind(h, (i32)90, (i32)114) == (i32)2);
    ck((u8*)"a touch there is the shield's", ux_ios_test_shield_tap(h, (i32)90, (i32)114) == (i32)1);
    ck((u8*)"...the canvas hears the press", gCanvas.presses == (i32)1);
    ck((u8*)"...at the point in the window's content coordinates", gCanvas.lastX == (i32)90 && gCanvas.lastY == (i32)114);
    ck((u8*)"...and the button under it does not fire", gFired == (i32)0);
    gCanvas.setHidden(true);
    gWin.displayAll();
    ux_ios_test_call_later((pointer)&hidden, (i32)300);
    }
void bare(void)
    {
    i32 h = gWin.handle;
    ck((u8*)"without a shield, UIKit's hit test finds the button", ux_ios_test_hit_kind(h, (i32)90, (i32)114) == (i32)1);
    UXView* root = gWin.contentView;
    gCanvas = new Canvas();
    root.addSubview(gCanvas, UXGeom.make((i16)0, (i16)0, (i16)300, (i16)300));
    gWin.displayAll();
    ux_ios_test_call_later((pointer)&shielded, (i32)300);
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
    gWin.open((u8*)"shield", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), new UXView());
    app.addWindow(gWin);
    gT = new Target();
    gBtn = new UXButton();
    gBtn.setTitle((u8*)"Press");
    gBtn.setAction(&gT.pressed);
    gWin.contentView.addSubview(gBtn, UXGeom.make((i16)40, (i16)100, (i16)100, (i16)28));
    gWin.displayAll();
    ux_ios_test_call_later((pointer)&bare, (i32)800);
    }
void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
    }
