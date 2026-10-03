// test_picker_android.xc — UXOpenPanel on Android is the system's document picker (the
// android-picker gate).  The app opens it; the GATE plays the user for real (uiautomator taps on
// the live screen): it picks a file it pushed to the device's Downloads, and the app must read its
// exact bytes through UXFileIO from the path it got back; then it presses Back at a second picker,
// which must give nothing.  Built with -D TABLE_ANDROID (the shared mobile-test glue).
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXOpenPanel.xc"
#import "UXFileIO.xc"

i32 gFails;

#if TABLE_ANDROID
extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);
void tWatchdog(void) { ux_and_test_watchdog((i32)20000, (i32)2); }
void tLater(pointer fn, i32 ms) { ux_and_test_call_later(fn, ms); }
void tQuit(i32 rc) { ux_and_quit(rc); }

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
bool sameBytes(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }

void pickTwice(void)
    {
    Stdio.printf("PICK1\n");
    u8* path = UXOpenPanel.run((u8*)"Open a note", (u8*)"");
    Stdio.printf("  (picked: %s)\n", path != (u8*)0 ? path : (u8*)"nothing");
    ck((u8*)"the picker gives back a path", path != (u8*)0);
    if (path != (u8*)0)
        {
        UXData* d = UXFileIO.read(path);
        bool ok = d != (UXData*)0;
        if (ok)
            {
            d.appendByte((u8)0);
            ok = sameBytes(d.bytes(), (u8*)"picked on the device, héllo\n");
            }
        ck((u8*)"...whose bytes UXFileIO reads exactly", ok);
        }
    Stdio.printf("PICK2\n");
    u8* none = UXOpenPanel.run((u8*)"Open another", (u8*)"");
    ck((u8*)"backing out of the picker gives nothing", none == (u8*)0);
    Stdio.printf(gFails == (i32)0 ? "PASS: UXOpenPanel on Android is the system document picker -- a real pick reads back, Back cancels\n" : "FAIL: %d\n", gFails);
    tLater((pointer)&finish, (i32)1000);
    }

void testBody(void)
    {
    gFails = (i32)0;
    ux_and_test_watchdog((i32)90000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXWindow* win = new UXWindow();
    win.open((u8*)"picker", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), new UXView());
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(win);
    win.displayAll();
    ck((u8*)"Android has a native open panel", gDriver.hasNativeFileOpen());
    tLater((pointer)&pickTwice, (i32)500);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
    }
