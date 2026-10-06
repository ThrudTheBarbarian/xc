// test_savepanel_android.xc — UXSavePanel on Android is the system's ACTION_CREATE_DOCUMENT (the
// android-savepanel gate).  The app opens it; the GATE plays the user for real (uiautomator taps on
// the live screen): it presses Save, which creates the document in Downloads under the default name.
// The app writes the staging path it got back through UXFileIO, twice, and the gate reads the
// document on the device after each.  Then it presses Back at a second save panel, which must give
// nothing.  Built with -D TABLE_ANDROID (the shared mobile-test glue).
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXWindow.xc"
#import "UXSavePanel.xc"
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

u8* gPath;
void cancelSave(void)
    {
    Stdio.printf("SAVE2\n");
    ck((u8*)"backing out of the save panel gives nothing", UXSavePanel.run((u8*)"Save another", (u8*)"", (u8*)"uxother.txt") == (u8*)0);
    Stdio.printf(gFails == (i32)0 ? "PASS: UXSavePanel on Android is ACTION_CREATE_DOCUMENT -- every write reaches the document, Back cancels\n" : "FAIL: %d\n", gFails);
    tLater((pointer)&finish, (i32)1000);
    }
void secondSave(void)
    {
    ck((u8*)"saving again succeeds", UXFileIO.write(gPath, UXStr.toData((u8*)"second draft\n")));
    Stdio.printf("WROTE2\n");
    tLater((pointer)&cancelSave, (i32)4000);
    }
void firstSave(void)
    {
    Stdio.printf("SAVE1\n");
    gPath = UXSavePanel.run((u8*)"Save the note", (u8*)"", (u8*)"uxsaved.txt");
    Stdio.printf("  (staging: %s)\n", gPath != (u8*)0 ? gPath : (u8*)"nothing");
    ck((u8*)"the save panel gives back a path to write", gPath != (u8*)0);
    if (gPath == (u8*)0)
        {
        tLater((pointer)&cancelSave, (i32)500);
        return;
        }
    ck((u8*)"...the app's own staging file", UXFileIO.read(gPath) != (Data*)0);
    ck((u8*)"a write to it succeeds", UXFileIO.write(gPath, UXStr.toData((u8*)"first draft, héllo\n")));
    Stdio.printf("WROTE1\n");
    tLater((pointer)&secondSave, (i32)4000);
    }

void testBody(void)
    {
    gFails = (i32)0;
    ux_and_test_watchdog((i32)90000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXWindow* win = new UXWindow();
    win.open((u8*)"savepanel", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), new UXView());
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(win);
    win.displayAll();
    ck((u8*)"Android has a native save panel", gDriver.hasNativeFileSave());
    tLater((pointer)&firstSave, (i32)500);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
    }
