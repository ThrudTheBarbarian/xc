// test_touch.xc — touches on DRAWN content on the touch backends (the ios-touch / android-touch gates).
//
// iOS and Android draw a window's UXKit content into one platform view; until now only the native
// widgets on top responded to a finger.  This drives touches through UXTouch: a tap on a drawn view
// is a press and a release; a drag stays with the view that took the press even when the finger
// leaves it (the window's grab); a drag on a scroll view's content pans it, finger and content
// moving together (on Android, where the touches go through the platform's own view dispatch, the
// native ScrollView pans itself); and on Android a native button still takes its own touch, the
// drawn content beneath never seeing it.
#import <Stdio.xc>
// One test, two backends: run_android_touch.sh builds it with -D TOUCH_ANDROID (Android is plain
// arm64 to the compiler, so there is no target symbol to test).
#if TOUCH_ANDROID
#import "UXAndroidDriver.xc"
#else
#import "UXIosDriver.xc"
#endif
#import "UXWindow.xc"
#import "UXScrollView.xc"
#import "UXControl.xc"

#if TOUCH_ANDROID
extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_touch(i32 handle, i32 phase, i32 x, i32 y);
extern void ux_and_test_call_later(pointer fn, i32 ms);
#else
extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_touch(i32 handle, i32 phase, i32 x, i32 y);
extern void ux_ios_test_call_later(pointer fn, i32 ms);
#endif

void quit(i32 rc)
    {
#if TOUCH_ANDROID
    ux_and_quit(rc);
#else
    ux_ios_quit(rc);
#endif
    }
void touch(i32 h, i32 phase, i32 x, i32 y)
    {
#if TOUCH_ANDROID
    ux_and_test_touch(h, phase, x, y);
#else
    ux_ios_test_touch(h, phase, x, y);
#endif
    }

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

// A drawn view that records what reaches it.
class Pad : UXView
    {
    i32 downs;
    i32 drags;
    i32 ups;
    i32 lastX;
    i32 lastY;
    void init(void)
        {
        super.init();
        downs = (i32)0;
        drags = (i32)0;
        ups = (i32)0;
        lastX = (i32)0;
        lastY = (i32)0;
        }
    void mouseDown(UXEvent* e)
        {
        downs = downs + (i32)1;
        lastX = (i32)e.x;
        lastY = (i32)e.y;
        }
    void mouseDragged(UXEvent* e)
        {
        drags = drags + (i32)1;
        lastX = (i32)e.x;
        lastY = (i32)e.y;
        }
    void mouseUp(UXEvent* e)
        {
        ups = ups + (i32)1;
        }
    }

// A row in a list: it takes a press (selection would happen here), and leaves drags alone -- they
// climb to the scroll view, which pans.
class Row : UXView
    {
    i32 downs;
    void init(void)
        {
        super.init();
        downs = (i32)0;
        }
    void mouseDown(UXEvent* e)
        {
        downs = downs + (i32)1;
        }
    }

i32 gButtonFired;
void onButton(UXControl* c)
    {
    gButtonFired = gButtonFired + (i32)1;
    }

UXWindow* gWin;
Pad* gPad;
Row* gRow;
UXScrollView* gSv;
i32 gPadDowns;
void afterButton(void)
    {
    ck((u8*)"a native button takes its own touch", gButtonFired == (i32)1);
    ck((u8*)"...and the drawn content beneath does not see it", gPad.downs == gPadDowns);
    finish();
    }
void finish(void)
    {
    Stdio.printf(gFails == (i32)0 ? "PASS: touches reach drawn content -- tap, drag with grab, pan\n" : "FAIL: %d\n", gFails);
    quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }

void touches(void)
    {
    i32 h = gWin.handle;
    Pad* pad = gPad;
    Row* row = gRow;
    UXScrollView* sv = gSv;

    // a tap on drawn content
    touch(h, (i32)0, (i32)60, (i32)50);
    touch(h, (i32)2, (i32)60, (i32)50);
    ck((u8*)"a tap is a press and a release", pad.downs == (i32)1 && pad.ups == (i32)1 && pad.drags == (i32)0);
    Stdio.printf("  (the press landed at %d,%d)\n", pad.lastX, pad.lastY);
    ck((u8*)"...at the point touched", pad.lastX == (i32)60 && pad.lastY == (i32)50);

    // a drag that leaves the view stays with it
    touch(h, (i32)0, (i32)100, (i32)60);
    touch(h, (i32)1, (i32)110, (i32)70);
    touch(h, (i32)1, (i32)150, (i32)100);
    touch(h, (i32)1, (i32)260, (i32)400); // far outside the pad
    touch(h, (i32)2, (i32)260, (i32)400);
    ck((u8*)"a drag reaches the view that took the press", pad.drags == (i32)3 && pad.ups == (i32)2);
    ck((u8*)"...even once the finger has left it", pad.lastX == (i32)260 && pad.lastY == (i32)400);

    // panning a scroll view: the press lands on a row, the drag moves the content
    ck((u8*)"the scroll view starts at the top", sv.scrollOffset == (i16)0);
    touch(h, (i32)0, (i32)100, (i32)180);
    touch(h, (i32)1, (i32)100, (i32)120);
    touch(h, (i32)1, (i32)100, (i32)30);
    touch(h, (i32)2, (i32)100, (i32)30);
    ck((u8*)"the row took the press", row.downs == (i32)1);
#if TOUCH_ANDROID
    // Android's touches go through the platform's own dispatch, so the drag reaches the native
    // ScrollView, which pans itself: with the finger, less the touch slop its first move spends.
    i32 moved = sv.scrollPx();
    Stdio.printf("  (the container panned to %d)\n", moved);
    ck((u8*)"a drag pans the native container with the finger", moved > (i32)40);
    // the release may have flung it on: a touch stops a fling, as a finger does, then measure from there
    touch(h, (i32)0, (i32)100, (i32)300);
    touch(h, (i32)2, (i32)100, (i32)300);
    i32 up = sv.scrollPx();
    touch(h, (i32)0, (i32)100, (i32)200);
    touch(h, (i32)1, (i32)100, (i32)240);
    touch(h, (i32)1, (i32)100, (i32)320);
    touch(h, (i32)2, (i32)100, (i32)320);
    Stdio.printf("  (from %d, back to %d)\n", up, sv.scrollPx());
    ck((u8*)"...and back down with it", sv.scrollPx() < up);
#else
    ck((u8*)"a drag pans the content by the finger's travel (150)", sv.scrollOffset == (i16)150);
    touch(h, (i32)0, (i32)100, (i32)200);
    touch(h, (i32)1, (i32)100, (i32)260);
    touch(h, (i32)2, (i32)100, (i32)260);
    ck((u8*)"...and back down (90)", sv.scrollOffset == (i16)90);
#endif

#if TOUCH_ANDROID
    // a native widget takes its own touch; the drawn content beneath never sees it
    i32 padDowns = pad.downs;
    gPadDowns = padDowns;
    touch(h, (i32)0, (i32)280, (i32)40);
    touch(h, (i32)2, (i32)280, (i32)40);
    // Android performs a click by POSTING it after the release: look on the next turns
    ux_and_test_call_later((pointer)&afterButton, (i32)300);
    return;
#endif
    finish();
    }

void testBody(void)
    {
    gFails = (i32)0;
    gButtonFired = (i32)0;
#if TOUCH_ANDROID
    ux_and_test_watchdog((i32)20000, (i32)2);
#else
    ux_ios_test_watchdog((i32)20000, (i32)2);
#endif
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        quit((i32)1);
        return;
        }
    ck((u8*)"drags arrive as events here, not a modal loop", !gDriver.dragTrackingIsModal());
    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"touch", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), content);
    UXApplication* app = new UXApplication();
    app.running = true; // the platform's loop is running it (a stopped app quits after a native event)
    gApp = app;
    app.addWindow(win);
    Pad* pad = new Pad();
    content.addSubview(pad, UXGeom.make((i16)20, (i16)20, (i16)200, (i16)120));
    UXButton* b = new UXButton();
    b.setTitle((u8*)"Native");
    b.setAction(&onButton);
    content.addSubview(b, UXGeom.make((i16)240, (i16)20, (i16)100, (i16)44));
    UXScrollView* sv = new UXScrollView();
    content.addSubview(sv, UXGeom.make((i16)20, (i16)160, (i16)300, (i16)200));
    Row* row = new Row(); // content inside the scroll view: takes the press, leaves the drag to the pan
    sv.document().addSubview(row, UXGeom.make((i16)0, (i16)0, (i16)280, (i16)40));
    sv.setDocumentHeight((i32)1000);
    win.tree.finalise();
    win.displayAll();
    gWin = win;
    gPad = pad;
    gRow = row;
    gSv = sv;
    // the touches come once the platform has laid the window out, as a finger's would
#if TOUCH_ANDROID
    ux_and_test_call_later((pointer)&touches, (i32)800);
#else
    ux_ios_test_call_later((pointer)&touches, (i32)800);
#endif
    }

void main(void)
    {
#if TOUCH_ANDROID
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
#else
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
#endif
    }
