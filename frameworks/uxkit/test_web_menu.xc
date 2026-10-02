// test_web_menu.xc — the menu bar on the web: a DOM bar on the page.  Under the node rig, what the
// page is handed (titles, items, separators, ticks, greying, text) and the state changes that
// follow it are checked, and a pick arriving through the ring (type 9) fires the item.  In real
// headless Chrome (run_web_menu.sh) the page builds the bar and a script clicks through it.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXMenu.xc"
#import "UXGeometry.xc"

extern i32 ux_test_menu(i32 t, i32 j);
extern i32 ux_test_menu_text(i32 t, i32 j, u8* out, i32 cap);
extern void ux_test_menu_done(void);
i32 gFails = 0;
void ck(bool ok, u8* what, i32 v)
    {
    Stdio.printf("  %s %s (%d)\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what, v);
    if (!ok)
        {
        gFails = gFails + 1;
        }
    }
i32 gNew;
i32 gQuit;
class Ctl : Object
    {
    void onNew(UXMenuItem* s) { gNew = gNew + (i32)1; }
    void onQuit(UXMenuItem* s) { gQuit = gQuit + (i32)1; }
    void onOther(UXMenuItem* s) { }
    }
bool sameText(i32 t, i32 j, u8* want)
    {
    u8 buf[64];
    ux_test_menu_text(t, j, &buf[(i32)0], (i32)64);
    i32 i = (i32)0;
    while (want[i] != (u8)0 && buf[i] == want[i])
        {
        i = i + (i32)1;
        }
    return want[i] == (u8)0 && buf[i] == (u8)0;
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
    UXWindow* win = new UXWindow();
    win.open((u8*)"Menus", UXGeom.make((i16)0, (i16)0, (i16)240, (i16)140), new UXView());
    app.addWindow(win);
    Ctl* c = new Ctl();
    UXMenuBar* bar = new UXMenuBar();
    UXMenu* file = bar.addMenu((u8*)"File");
    file.addItem((u8*)"New \"draft\"", &c.onNew);
    file.addSeparator();
    file.addItem((u8*)"Quit", &c.onQuit);
    UXMenu* view = bar.addMenu((u8*)"View");
    UXMenuItem* grid = view.addItem((u8*)"Grid", &c.onOther);
    grid.checked = true;
    UXMenuItem* off = view.addItem((u8*)"Rulers", &c.onOther);
    off.enabled = false;
    app.setMenuBar(bar);
    if (ux_test_menu((i32)-1, (i32)0) >= (i32)0)
        {
        // the node rig: what the page was handed
        ck(ux_test_menu((i32)-1, (i32)0) == (i32)2, "the page gets two titles", ux_test_menu((i32)-1, (i32)0));
        ck(sameText((i32)0, (i32)-1, (u8*)"File") && sameText((i32)1, (i32)-1, (u8*)"View"), "titled File and View", (i32)0);
        ck(ux_test_menu((i32)0, (i32)-1) == (i32)3, "File has three entries", ux_test_menu((i32)0, (i32)-1));
        ck(sameText((i32)0, (i32)0, (u8*)"New \"draft\""), "an item's text survives JSON (quotes escaped)", (i32)0);
        ck(ux_test_menu((i32)0, (i32)1) == (i32)4, "the second is a separator", ux_test_menu((i32)0, (i32)1));
        ck(ux_test_menu((i32)1, (i32)0) == (i32)3, "View > Grid is ticked", ux_test_menu((i32)1, (i32)0));
        ck(ux_test_menu((i32)1, (i32)1) == (i32)0, "View > Rulers is greyed", ux_test_menu((i32)1, (i32)1));
        bar.setChecked((u16)1, (u16)0, false);
        bar.setEnabled((u16)1, (u16)1, true);
        ck(ux_test_menu((i32)1, (i32)0) == (i32)1 && ux_test_menu((i32)1, (i32)1) == (i32)1,
           "setChecked and setEnabled reach the page", ux_test_menu((i32)1, (i32)0) * (i32)10 + ux_test_menu((i32)1, (i32)1));
        // a pick, as the page pushes it into the ring
        i32 r[8];
        UXEvent* ev = new UXEvent();
        r[0] = (i32)9;
        r[1] = (i32)0;
        r[2] = (i32)2;
        r[3] = (i32)0;
        wd.decodeRing(&r[(i32)0], ev);
        app.dispatchEvent(ev);
        ck(gQuit == (i32)1 && gNew == (i32)0, "a pick through the ring (type 9: File, item 2) fires Quit", gQuit);
        Stdio.printf(gFails == 0 ? "PASS: web menus (node rig) -- the page gets the bar, its state, and picks come back\n" : "FAIL: %d\n", gFails);
        }
    ux_test_menu_done();
    }
