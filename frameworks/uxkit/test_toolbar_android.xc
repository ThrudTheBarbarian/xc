// test_toolbar_android.xc — UXToolbar on Android is a real android.widget.Toolbar (the
// android-toolbar gate): its buttons are action items of the Toolbar's menu (spaces have no
// counterpart there), and a REAL tap on an item (the gate finds it on screen with uiautomator and taps
// it with adb input) fires the toolbar's action with that item selected in the model.
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXToolbar.xc"

extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);
extern i32 ux_and_test_toolbar_count(i32 handle, i32 node);
extern i32 ux_and_test_toolbar_title_is(i32 handle, i32 node, i32 i, u8* want);

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
i32 gFiredTag;
UXToolbar* gBar;
UXWindow* gWin;
class Target : Object
    {
    void clicked(UXControl* sender)
        {
        gFired = gFired + (i32)1;
        UXToolbar* t = (UXToolbar* ?)sender;
        gFiredTag = t != (UXToolbar*)0 && t.selection() >= (i32)0 ? t.itemAt(t.selection()).tag : (i32)-1;
        }
    }
Target* gTarget;

void finish(void)
    {
    ux_and_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
i32 gStep;
i32 gWaited;
void step(void)
    {
    i32 want = gStep == (i32)1 ? (i32)1 : (i32)2;
    if (gFired < want && gWaited < (i32)150)
        {
        gWaited = gWaited + (i32)1;
        ux_and_test_call_later((pointer)&step, (i32)100);
        return;
        }
    if (gStep == (i32)1)
        {
        ck((u8*)"a real tap on Delete fires the toolbar's action", gFired == (i32)1);
        ck((u8*)"...with Delete the selected item", gFiredTag == (i32)12);
        gStep = (i32)2;
        gWaited = (i32)0;
        Stdio.printf("TAPTEXT New\n");
        ux_and_test_call_later((pointer)&step, (i32)100);
        return;
        }
    ck((u8*)"and a real tap on New fires it with New", gFired == (i32)2 && gFiredTag == (i32)10);
    Stdio.printf(gFails == (i32)0 ? "PASS: UXToolbar on Android is a real Toolbar -- its items are its actions, a real tap fires with that item\n" : "FAIL: %d\n", gFails);
    ux_and_test_call_later((pointer)&finish, (i32)1000);
    }
void checks(void)
    {
    i32 h = gWin.handle;
    i32 n = (i32)gBar.index;
    ck((u8*)"the toolbar is a real Toolbar with three actions (its spaces have no counterpart)", ux_and_test_toolbar_count(h, n) == (i32)3);
    ck((u8*)"...titled as the model's items", ux_and_test_toolbar_title_is(h, n, (i32)0, (u8*)"New") != (i32)0 &&
                                           ux_and_test_toolbar_title_is(h, n, (i32)1, (u8*)"Open") != (i32)0 &&
                                           ux_and_test_toolbar_title_is(h, n, (i32)2, (u8*)"Delete") != (i32)0);
    gStep = (i32)1;
    gWaited = (i32)0;
    Stdio.printf("TAPTEXT Delete\n");
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
    gWin.open((u8*)"toolbar", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), root);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(gWin);
    gTarget = new Target();
    gBar = new UXToolbar();
    gBar.addItem((u8*)"new", (u8*)"New", (i32)10, (i16)60);
    gBar.addSpace();
    gBar.addItem((u8*)"open", (u8*)"Open", (i32)11, (i16)60);
    gBar.addFlexibleSpace();
    gBar.addItem((u8*)"delete", (u8*)"Delete", (i32)12, (i16)60);
    gBar.setAction(&gTarget.clicked);
    root.addSubview(gBar, UXGeom.make((i16)0, (i16)80, (i16)sw, (i16)56));
    gWin.displayAll();
    ux_and_test_call_later((pointer)&checks, (i32)1500);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
    }
