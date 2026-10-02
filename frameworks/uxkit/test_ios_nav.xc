// test_ios_nav.xc — the navigation stack is a REAL UINavigationController on iOS (the ios-nav gate).
//
// UXNavigationController hands every push and pop to the platform: the bar, the Back button titled
// with the form underneath, the push animation and the edge-swipe are UIKit's own.  This drives it in
// the simulator: two pushes; the native stack's depth and titles; the live window content in the top
// view controller; the swipe gesture present; then the USER's Back (what the bar's button does) --
// the model must follow and the delegate hear it -- and an app pop, which must not echo back.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXNavigationController.xc"
#import "UXControl.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_call_later(pointer fn, i32 ms);
extern i32 ux_ios_test_nav_depth(pointer nav);
extern i32 ux_ios_test_nav_title_is(pointer nav, i32 fromTop, u8* want);
extern i32 ux_ios_test_nav_live_on_top(pointer nav);
extern i32 ux_ios_test_nav_swipe_enabled(pointer nav);
extern void ux_ios_test_nav_user_back(pointer nav);
extern i32 ux_ios_test_control_visible(i32 handle, u8* title);

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
    i32 shows;
    i32 hides;
    i32 lastShowDepth;
    void init(void)
        {
        shows = (i32)0;
        hides = (i32)0;
        lastShowDepth = (i32)0;
        }
    void formWillShow(UXNavigationController* n, UXView* content, i32 depth)
        {
        shows = shows + (i32)1;
        lastShowDepth = depth;
        }
    void formDidHide(UXNavigationController* n, UXView* content, i32 depth)
        {
        hides = hides + (i32)1;
        }
    }

UXWindow* gWin;
UXNavigationController* gNav;
Watcher* gWatch;

// Push a form, then build into it (a view can only take subviews once it is in a window's tree).
void pushForm(u8* title, u8* label)
    {
    UXView* v = new UXView();
    gNav.push(title, v);
    UXButton* b = new UXButton();
    b.setTitle(label);
    v.addSubview(b, UXGeom.make((i16)20, (i16)30, (i16)200, (i16)44));
    }

void step4(void)
    {
    ck((u8*)"an app pop: the native stack follows", ux_ios_test_nav_depth(gNav.nativeNav) == (i32)1);
    ck((u8*)"...the live view is back on top", ux_ios_test_nav_live_on_top(gNav.nativeNav) != (i32)0);
    ck((u8*)"...and it did not echo back as a second pop", gNav.depth() == (i32)1);
    Stdio.printf(gFails == (i32)0 ? "PASS: navigation is a real UINavigationController on iOS\n" : "FAIL: %d\n", gFails);
    ux_ios_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void step3(void)
    {
    ck((u8*)"the user's Back pops the MODEL too", gNav.depth() == (i32)1);
    ck((u8*)"...the delegate heard the root re-shown", gWatch.lastShowDepth == (i32)1);
    ck((u8*)"...the native stack is one deep", ux_ios_test_nav_depth(gNav.nativeNav) == (i32)1);
    ck((u8*)"...and the live view moved to the revealed form", ux_ios_test_nav_live_on_top(gNav.nativeNav) != (i32)0);
    ck((u8*)"only the root's content is showing", !gNav.contentAt((i32)0).isHidden());
    ck((u8*)"...its native button visible again", ux_ios_test_control_visible(gWin.handle, (u8*)"Open") != (i32)0);
    ck((u8*)"...and the popped form's hidden", ux_ios_test_control_visible(gWin.handle, (u8*)"Reply") == (i32)0);
    // an app-initiated push and pop
    pushForm((u8*)"Again", (u8*)"Again");
    gNav.pop();
    gApp.displayIfNeeded();
    ux_ios_test_call_later((pointer)&step4, (i32)1200);
    }
void step2(void)
    {
    pointer n = gNav.nativeNav;
    ck((u8*)"the controller handed over to a native stack", gNav.isNative());
    ck((u8*)"two view controllers", ux_ios_test_nav_depth(n) == (i32)2);
    ck((u8*)"the top is titled Message", ux_ios_test_nav_title_is(n, (i32)0, (u8*)"Message") != (i32)0);
    ck((u8*)"the one under it Inbox (what Back reads)", ux_ios_test_nav_title_is(n, (i32)1, (u8*)"Inbox") != (i32)0);
    ck((u8*)"the live window content is in the top view controller", ux_ios_test_nav_live_on_top(n) != (i32)0);
    ck((u8*)"the edge-swipe is there", ux_ios_test_nav_swipe_enabled(n) != (i32)0);
    ck((u8*)"the pushed form's native button is on screen", ux_ios_test_control_visible(gWin.handle, (u8*)"Reply") != (i32)0);
    ck((u8*)"...and the covered form's is hidden", ux_ios_test_control_visible(gWin.handle, (u8*)"Open") == (i32)0);
    ux_ios_test_nav_user_back(n);
    ux_ios_test_call_later((pointer)&step3, (i32)1200);
    }
void step1(void)
    {
    ck((u8*)"attached at the first push in a window", gNav.isNative());
    pushForm((u8*)"Message", (u8*)"Reply");
    gWin.tree.finalise();
    gApp.displayIfNeeded(); // what every event handler ends with: realizes what the new form brought
    ck((u8*)"model: two deep", gNav.depth() == (i32)2);
    ux_ios_test_call_later((pointer)&step2, (i32)1200);
    }

void testBody(void)
    {
    gFails = (i32)0;
    ux_ios_test_watchdog((i32)20000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        ux_ios_quit((i32)1);
        return;
        }
    ck((u8*)"iOS has a native navigation stack", gDriver.hasNativeNavigation());
    UXView* content = new UXView();
    gWin = new UXWindow();
    gNav = new UXNavigationController();
    gWatch = new Watcher();
    gNav.setDelegate(gWatch);
    gWin.open((u8*)"nav", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), content);
    UXApplication* app = new UXApplication(); // the test plays the app: its window, its display passes
    gApp = app;
    app.addWindow(gWin);
    content.addSubview(gNav, UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh));
    pushForm((u8*)"Inbox", (u8*)"Open");
    gWin.tree.finalise();
    gWin.displayAll();
    ux_ios_test_call_later((pointer)&step1, (i32)800);
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run(); // UIApplicationMain — never returns
    }
