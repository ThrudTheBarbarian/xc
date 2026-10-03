// test_toolbar_ios.xc — UXToolbar on iOS is a real UIToolbar (the ios-toolbar gate): its items one to
// one (buttons by label, a fixed space, UIKit's own flexible space), and a tap on an item, sent as
// UIKit sends one (the simulator has no tap injection), firing the toolbar's action with that item
// selected in the model.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXToolbar.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_call_later(pointer fn, i32 ms);
extern i32 ux_ios_test_toolbar_count(i32 handle, i32 node);
extern i32 ux_ios_test_toolbar_title_is(i32 handle, i32 node, i32 i, u8* want);
extern i32 ux_ios_test_toolbar_is_flexible(i32 handle, i32 node, i32 i);
extern void ux_ios_test_toolbar_tap(i32 handle, i32 node, i32 i);

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

void checks(void)
    {
    i32 h = gWin.handle;
    i32 n = (i32)gBar.index;
    ck((u8*)"the toolbar is a real UIToolbar of five items", ux_ios_test_toolbar_count(h, n) == (i32)5);
    ck((u8*)"...its buttons titled as the model's items", ux_ios_test_toolbar_title_is(h, n, (i32)0, (u8*)"New") != (i32)0 &&
                                                       ux_ios_test_toolbar_title_is(h, n, (i32)2, (u8*)"Open") != (i32)0 &&
                                                       ux_ios_test_toolbar_title_is(h, n, (i32)4, (u8*)"Delete") != (i32)0);
    ck((u8*)"...with UIKit's own flexible space", ux_ios_test_toolbar_is_flexible(h, n, (i32)3) != (i32)0);
    ux_ios_test_toolbar_tap(h, n, (i32)4);
    ck((u8*)"a tap on Delete fires the toolbar's action", gFired == (i32)1);
    ck((u8*)"...with Delete the selected item", gFiredTag == (i32)12);
    ux_ios_test_toolbar_tap(h, n, (i32)0);
    ck((u8*)"and a tap on New fires it with New", gFired == (i32)2 && gFiredTag == (i32)10);
    Stdio.printf(gFails == (i32)0 ? "PASS: UXToolbar on iOS is a real UIToolbar -- its items one to one, a tap fires with that item\n" : "FAIL: %d\n", gFails);
    ux_ios_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }

void testBody(void)
    {
    gFails = (i32)0;
    gFired = (i32)0;
    ux_ios_test_watchdog((i32)30000, (i32)2);
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
    root.addSubview(gBar, UXGeom.make((i16)0, (i16)40, (i16)sw, (i16)44));
    gWin.displayAll();
    ux_ios_test_call_later((pointer)&checks, (i32)800);
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
    }
