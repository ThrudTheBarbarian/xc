// test_picker_ios.xc — UXOpenPanel on iOS is the system document picker (the ios-picker gate).
// The simulator offers no way to drive another process's UI, so the test answers the REAL picker
// (shown, and checked to be on screen) through its own delegate, exactly as UIKit does: first with a
// file the test wrote (an import-mode picker hands its delegate the copy's URL), which UXFileIO must
// read back; then with a cancel, which must give nothing.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXOpenPanel.xc"
#import "UXFileIO.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_call_later(pointer fn, i32 ms);
extern i32 ux_ios_test_picker_shown(void);
extern void ux_ios_test_picker_answer(u8* path);
u8* getenv(u8* name);

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
bool sameBytes(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }

u8* gFile;
i32 gAnswer;
// the "user", while the picker is up: check it is on screen, then pick (1) or cancel (2)
void user(void)
    {
    ck((u8*)"the system picker is on screen", ux_ios_test_picker_shown() != (i32)0);
    ux_ios_test_picker_answer(gAnswer == (i32)1 ? gFile : (u8*)0);
    }

void picks(void)
    {
    // a file standing in for the provider's copy, in the app's tmp space
    Data* p = UXStr.toData(getenv((u8*)"TMPDIR"));
    p.appendBytes((u8*)"/uxpick.txt", (i32)11);
    p.appendByte((u8)0);
    gFile = p.bytes();
    UXFileIO.write(gFile, UXStr.toData((u8*)"picked on the device, héllo"));

    gAnswer = (i32)1;
    ux_ios_test_call_later((pointer)&user, (i32)1200);
    u8* path = UXOpenPanel.run((u8*)"Open a note", (u8*)"");
    ck((u8*)"the picker gives back the picked file's path", path != (u8*)0 && sameBytes(path, gFile));
    Data* d = path != (u8*)0 ? UXFileIO.read(path) : (Data*)0;
    bool same = d != (Data*)0;
    if (same)
        {
        d.appendByte((u8)0);
        same = sameBytes(d.bytes(), (u8*)"picked on the device, héllo");
        }
    ck((u8*)"...whose bytes UXFileIO reads", same);

    gAnswer = (i32)2;
    ux_ios_test_call_later((pointer)&user, (i32)1200);
    ck((u8*)"cancelling the picker gives nothing", UXOpenPanel.run((u8*)"Open another", (u8*)"") == (u8*)0);
    Stdio.printf(gFails == (i32)0 ? "PASS: UXOpenPanel on iOS is the system document picker -- a pick reads back, a cancel gives nothing\n" : "FAIL: %d\n", gFails);
    ux_ios_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }

void testBody(void)
    {
    gFails = (i32)0;
    ux_ios_test_watchdog((i32)30000, (i32)2);
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
    ck((u8*)"iOS has a native open panel", gDriver.hasNativeFileOpen());
    ux_ios_test_call_later((pointer)&picks, (i32)300);
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
    }
