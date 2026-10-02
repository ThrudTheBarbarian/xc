// test_web_popup.xc — a popup button's list on the web: the page shows it (ux_web_page.js), and the
// pick comes back through the ring.  Under the node rig: a click hands the page the items and the
// current choice and fires nothing yet; the pick (ring type 10 with the driver's token) selects and
// fires once; a pick carrying an older token is ignored.  In real headless Chrome
// (run_web_popup.sh) the page shows the list at the button and a click on an item reports it.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXPopUpButton.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

extern i32 ux_test_popup(i32 what);
extern void ux_test_popup_done(i32 token);
i32 gFails = 0;
void ck(bool ok, u8* what, i32 v)
    {
    Stdio.printf("  %s %s (%d)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, v);
    if (!ok)
        {
        gFails = gFails + 1;
        }
    }
i32 gFired;
class Ctl : Object
    {
    void onPick(UXControl* c) { gFired = gFired + (i32)1; }
    }
void main(void)
    {
    UXWebDriver* wd = new UXWebDriver();
    gDriver = wd;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
    gApp = app;
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"Popup", UXGeom.make((i16)0, (i16)0, (i16)240, (i16)140), content);
    app.addWindow(win);
    UXPopUpButton* pop = new UXPopUpButton();
    pop.addItem((u8*)"Red", (i32)1);
    pop.addItem((u8*)"Green", (i32)2);
    pop.addItem((u8*)"Blue", (i32)3);
    pop.selectItem((i32)1);
    content.addSubview(pop, UXGeom.make((i16)20, (i16)30, (i16)140, (i16)26));
    Ctl* c = new Ctl();
    pop.setAction(&c.onPick);
    win.displayAll();
    UXEvent* click = new UXEvent();
    click.kind = (u8)UXEventMouseDown;
    click.x = (i16)60;
    click.y = (i16)40;
    pop.mouseDown(click); // what a click on the button does
    i32 token = ux_test_popup((i32)-1);
    if (token != (i32)-100 && ux_test_popup((i32)-2) >= (i32)0 && token > (i32)0)
        {
        ck(ux_test_popup((i32)-2) == (i32)3 && ux_test_popup((i32)-3) == (i32)1, "the page gets three items, Green current", ux_test_popup((i32)-2));
        ck(ux_test_popup((i32)1) == (i32)5, "item 1's title is Green", ux_test_popup((i32)1));
        ck(gFired == (i32)0 && pop.selectedIndex() == (i32)1, "opening fires nothing and changes nothing", gFired);
        i32 r[8];
        UXEvent* ev = new UXEvent();
        r[0] = (i32)10;
        r[1] = token - (i32)1; // a stale token
        r[2] = (i32)0;
        wd.decodeRing(&r[(i32)0], ev);
        ck(gFired == (i32)0 && pop.selectedIndex() == (i32)1, "a pick with an older token is ignored", gFired);
        r[1] = token;
        r[2] = (i32)2;
        wd.decodeRing(&r[(i32)0], ev);
        ck(pop.selectedIndex() == (i32)2 && gFired == (i32)1, "the pick through the ring selects Blue and fires once", pop.selectedIndex());
        Stdio.printf(gFails == 0 ? "PASS: web popup (node rig) -- the page gets the list, the pick comes back once\n" : "FAIL: %d\n", gFails);
        }
    ux_test_popup_done(token);
    }
