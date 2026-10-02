// test_navtree.xc — UXNavigationController in a real window tree, where it draws its own bar (AppKit,
// headless): only the top form is visible -- after a push, after a pop (the popped form must be hidden,
// not left showing over the one revealed), and after popToRoot.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXWindow.xc"
#import "UXNavigationController.xc"

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
void main(void)
    {
    gFails = (i32)0;
    ux_ak_set_capture((i32)1);
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no AppKit boot\n");
        return;
        }
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"nav", UXGeom.make((i16)0, (i16)0, (i16)400, (i16)300), content);
    UXNavigationController* nav = new UXNavigationController();
    content.addSubview(nav, UXGeom.make((i16)0, (i16)0, (i16)400, (i16)300));
    ck((u8*)"the desktop draws its own bar", !d.hasNativeNavigation());
    UXView* a = new UXView();
    UXView* b = new UXView();
    UXView* c = new UXView();
    nav.push((u8*)"A", a);
    nav.push((u8*)"B", b);
    nav.push((u8*)"C", c);
    ck((u8*)"after three pushes only the top is visible", a.isHidden() && b.isHidden() && !c.isHidden());
    ck((u8*)"...below the bar", (i32)c.frame().y == (i32)nav.barHeight());
    nav.pop();
    ck((u8*)"a pop shows the one revealed", !b.isHidden());
    ck((u8*)"...and HIDES the one popped", c.isHidden());
    nav.push((u8*)"C", c);
    ck((u8*)"a popped form can be pushed again", !c.isHidden() && b.isHidden());
    nav.popToRoot();
    ck((u8*)"popToRoot: only the root shows", !a.isHidden() && b.isHidden() && c.isHidden());
    win.close();
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the navigation stack in a window tree -- only the top form shows\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
