// test_android_nav.xc — the navigation stack on Android's own bar and Back (the android-nav gate).
//
// UXNavigationController hands its pushes and pops to the platform: a Toolbar showing the top form's
// title and, when there is somewhere to go back to, the theme's Up arrow; and the system Back,
// caught with an OnBackInvokedCallback that is registered only while there is something to pop.
// Driven on the emulator: two pushes; the bar's title and Up; the Back callback registered; the
// covered form's widgets hidden; then Up, and the system Back, each popping the MODEL (the delegate
// hears it, the revealed form's widgets come back); and at the root the callback is gone, so Back
// leaves the app as it should.
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXNavigationController.xc"
#import "UXControl.xc"

extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);
extern i32 ux_and_test_nav_title_is(pointer nav, u8* want);
extern i32 ux_and_test_nav_has_up(pointer nav);
extern i32 ux_and_test_nav_back_registered(pointer nav);
extern void ux_and_test_nav_press_up(pointer nav);
extern void ux_and_test_nav_system_back(pointer nav);
extern i32 ux_and_test_control_visible(i32 handle, u8* title);

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

class Watcher : Object<UXNavigationDelegate>
    {
    i32 lastShowDepth;
    void init(void)
        {
        lastShowDepth = (i32)0;
        }
    void formWillShow(UXNavigationController* n, UXView* content, i32 depth)
        {
        lastShowDepth = depth;
        }
    }

UXWindow* gWin;
UXNavigationController* gNav;
Watcher* gWatch;

void pushForm(u8* title, u8* label)
    {
    UXView* v = new UXView();
    gNav.push(title, v);
    UXButton* b = new UXButton();
    b.setTitle(label);
    v.addSubview(b, UXGeom.make((i16)20, (i16)30, (i16)200, (i16)44));
    gWin.tree.finalise();
    gApp.displayIfNeeded();
    }

void step3(void)
    {
    ck((u8*)"the system Back pops the model", gNav.depth() == (i32)1);
    ck((u8*)"...the bar says Inbox again, with no Up", ux_and_test_nav_title_is(gNav.nativeNav, (u8*)"Inbox") != (i32)0 && ux_and_test_nav_has_up(gNav.nativeNav) == (i32)0);
    ck((u8*)"...and at the root Back is the system's again (callback unregistered)", ux_and_test_nav_back_registered(gNav.nativeNav) == (i32)0);
    ck((u8*)"...the root's button is back", ux_and_test_control_visible(gWin.handle, (u8*)"Open") != (i32)0);
    Stdio.printf(gFails == (i32)0 ? "PASS: navigation is Android's own bar and Back\n" : "FAIL: %d\n", gFails);
    ux_and_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void step2(void)
    {
    ck((u8*)"Up pops the model", gNav.depth() == (i32)2);
    ck((u8*)"...the delegate heard Message re-shown", gWatch.lastShowDepth == (i32)2);
    ck((u8*)"...the bar follows", ux_and_test_nav_title_is(gNav.nativeNav, (u8*)"Message") != (i32)0);
    ck((u8*)"...the popped form's button is hidden", ux_and_test_control_visible(gWin.handle, (u8*)"Details") == (i32)0);
    ck((u8*)"...the revealed one's shown", ux_and_test_control_visible(gWin.handle, (u8*)"Reply") != (i32)0);
    ux_and_test_nav_system_back(gNav.nativeNav);
    ux_and_test_call_later((pointer)&step3, (i32)500);
    }
void step1(void)
    {
    pushForm((u8*)"Message", (u8*)"Reply");
    pushForm((u8*)"Details", (u8*)"Details");
    pointer n = gNav.nativeNav;
    ck((u8*)"the controller handed over to the native bar", gNav.isNative());
    ck((u8*)"the bar is titled Details", ux_and_test_nav_title_is(n, (u8*)"Details") != (i32)0);
    ck((u8*)"...with the Up arrow", ux_and_test_nav_has_up(n) != (i32)0);
    ck((u8*)"Back is registered while there is something to pop", ux_and_test_nav_back_registered(n) != (i32)0);
    ck((u8*)"the top form's button shows", ux_and_test_control_visible(gWin.handle, (u8*)"Details") != (i32)0);
    ck((u8*)"...the covered ones' do not", ux_and_test_control_visible(gWin.handle, (u8*)"Open") == (i32)0 && ux_and_test_control_visible(gWin.handle, (u8*)"Reply") == (i32)0);
    ux_and_test_nav_press_up(n);
    ux_and_test_call_later((pointer)&step2, (i32)500);
    }

void testBody(void)
    {
    gFails = (i32)0;
    ux_and_test_watchdog((i32)20000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_and_quit((i32)1);
        return;
        }
    ck((u8*)"Android has a native navigation bar", gDriver.hasNativeNavigation());
    UXView* content = new UXView();
    gWin = new UXWindow();
    gWin.open((u8*)"nav", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), content);
    UXApplication* app = new UXApplication(); // the test plays the app: its window, its display passes
    gApp = app;
    app.addWindow(gWin);
    gNav = new UXNavigationController();
    gWatch = new Watcher();
    gNav.setDelegate(gWatch);
    content.addSubview(gNav, UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh));
    pushForm((u8*)"Inbox", (u8*)"Open");
    ux_and_test_call_later((pointer)&step1, (i32)800);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
    }
