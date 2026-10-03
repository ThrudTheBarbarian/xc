// test_menu_native.xc — an app's menus on the mobile platforms, which have no menu bar: a "more"
// button with a UIMenu on iOS (ios-menu), an overflow button with a PopupMenu on Android
// (android-menu, built with -D TABLE_ANDROID), each with a submenu per title.  Checked: the titles
// and items as the native menu holds them, check and enable changes reaching it, a pick firing the
// item's bound action (on Android a REAL one: the gate taps the button, File, then New, through
// uiautomator), and a disabled item not firing.
#import <Stdio.xc>
#if TABLE_ANDROID
#import "UXAndroidDriver.xc"
#else
#import "UXIosDriver.xc"
#endif
#import "UXWindow.xc"
#import "UXMenu.xc"

i32 gFails;

#if TABLE_ANDROID
extern i32 ux_and_test_menu_shown(void);
extern i32 ux_and_test_menu_title_is(i32 t, u8* want);
extern i32 ux_and_test_menu_item(i32 t, i32 j);
i32 mShown() { return ux_and_test_menu_shown(); }
i32 mTitleIs(i32 t, u8* w) { return ux_and_test_menu_title_is(t, w); }
i32 mItem(i32 t, i32 j) { return ux_and_test_menu_item(t, j); }
extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);
void tWatchdog(void) { ux_and_test_watchdog((i32)20000, (i32)2); }
void tLater(pointer fn, i32 ms) { ux_and_test_call_later(fn, ms); }
void tQuit(i32 rc) { ux_and_quit(rc); }
#else
extern i32 ux_ios_test_menu_shown(void);
extern i32 ux_ios_test_menu_title_is(i32 t, u8* want);
extern i32 ux_ios_test_menu_item(i32 t, i32 j);
extern void ux_ios_test_menu_pick(i32 t, i32 j);
i32 mShown() { return ux_ios_test_menu_shown(); }
i32 mTitleIs(i32 t, u8* w) { return ux_ios_test_menu_title_is(t, w); }
i32 mItem(i32 t, i32 j) { return ux_ios_test_menu_item(t, j); }
extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_call_later(pointer fn, i32 ms);
void tWatchdog(void) { ux_ios_test_watchdog((i32)20000, (i32)2); }
void tLater(pointer fn, i32 ms) { ux_ios_test_call_later(fn, ms); }
void tQuit(i32 rc) { ux_ios_quit(rc); }
#endif
void finish(void)
    {
    tQuit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
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
void verdict(void)
    {
    Stdio.printf(gFails == (i32)0 ? "PASS: the app's menus are the platform's native menu -- titles, items, state, a pick fires its action\n" : "FAIL: %d\n", gFails);
    tLater((pointer)&finish, (i32)2500);
    }

i32 gNew;
i32 gSave;
i32 gGrid;
class Ctl : Object
    {
    void onNew(UXMenuItem* s)
        {
        gNew = gNew + (i32)1;
        Stdio.printf("menu: File > New fired\n");
        }
    void onOpen(UXMenuItem* s)
        {
        }
    void onSave(UXMenuItem* s)
        {
        gSave = gSave + (i32)1;
        }
    void onGrid(UXMenuItem* s)
        {
        gGrid = gGrid + (i32)1;
        }
    }
Ctl* gCtl;
UXMenuBar* gBar;
UXWindow* gWin;

void afterRealTaps(void)
    {
    ck((u8*)"a REAL tap on the button, File, then New fires New's action", gNew == (i32)1);
    verdict();
    }

void testBody(void)
    {
    gFails = (i32)0;
    tWatchdog();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        tQuit((i32)1);
        return;
        }
    gWin = new UXWindow();
    gWin.open((u8*)"menus", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), new UXView());
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(gWin);
    gCtl = new Ctl();
    gBar = new UXMenuBar();
    UXMenu* file = gBar.addMenu((u8*)"File");
    file.addItem((u8*)"New", &gCtl.onNew);
    file.addItem((u8*)"Open…", &gCtl.onOpen);
    file.addSeparator();
    file.addItem((u8*)"Save", &gCtl.onSave);
    UXMenu* view = gBar.addMenu((u8*)"View");
    view.addItem((u8*)"Grid", &gCtl.onGrid);
    app.setMenuBar(gBar);
    gWin.displayAll();

    ck((u8*)"the native menu carries the app's two titles", mShown() == (i32)2);
    ck((u8*)"...File and View", mTitleIs((i32)0, (u8*)"File") != (i32)0 && mTitleIs((i32)1, (u8*)"View") != (i32)0);
    ck((u8*)"...File's items, the separator not an item", mItem((i32)0, (i32)0) == (i32)1 && mItem((i32)0, (i32)1) == (i32)1
       && mItem((i32)0, (i32)2) == (i32)0 && mItem((i32)0, (i32)3) == (i32)1);
    gBar.setChecked((u16)1, (u16)0, true);
    ck((u8*)"a check reaches the native item", mItem((i32)1, (i32)0) == (i32)3);
    gBar.setEnabled((u16)0, (u16)3, false);
    ck((u8*)"...and so does disabling one", mItem((i32)0, (i32)3) == (i32)5);
#if TABLE_ANDROID
    Stdio.printf("MENUREADY\n");
    tLater((pointer)&afterRealTaps, (i32)14000);
#else
    ux_ios_test_menu_pick((i32)0, (i32)0);
    ck((u8*)"picking File > New fires its action", gNew == (i32)1);
    ux_ios_test_menu_pick((i32)0, (i32)3);
    ck((u8*)"...a disabled item does not fire", gSave == (i32)0);
    ux_ios_test_menu_pick((i32)1, (i32)0);
    ck((u8*)"...and View > Grid fires its own", gGrid == (i32)1 && gNew == (i32)1);
    verdict();
#endif
    }

void main(void)
    {
#if TABLE_ANDROID
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
#else
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
#endif
    }
