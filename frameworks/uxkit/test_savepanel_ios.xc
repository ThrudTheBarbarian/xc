// test_savepanel_ios.xc — UXSavePanel on iOS is the system's export picker (the ios-savepanel gate).
// The panel asks where the document goes before anything is written, and hands back a staging path in
// the app's own space; each UXFileIO.write to it is copied on to the chosen document.  As in
// ios-picker, the test answers the REAL picker (checked to be on screen) through its own delegate:
// first with a destination it names, then with a cancel.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXSavePanel.xc"
#import "UXFileIO.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_call_later(pointer fn, i32 ms);
extern i32 ux_ios_test_export_shown(void);
extern void ux_ios_test_export_answer(u8* destPath);
i32 mkdir(u8* path, u32 mode);
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

u8* gDest;
i32 gAnswer;
// the "user", while the export picker is up: check it is on screen, then choose (1) or cancel (2)
void user(void)
    {
    ck((u8*)"the system export picker is on screen", ux_ios_test_export_shown() != (i32)0);
    ux_ios_test_export_answer(gAnswer == (i32)1 ? gDest : (u8*)0);
    }
// the text of a file, or "" if it cannot be read
u8* textOf(u8* path)
    {
    UXData* d = UXFileIO.read(path);
    if (d == (UXData*)0)
        {
        return (u8*)"";
        }
    d.appendByte((u8)0);
    return d.bytes();
    }

void saves(void)
    {
    // the document the user chooses: a file in a folder of its own, standing in for the provider's
    UXData* p = UXData.fromString(getenv((u8*)"TMPDIR"));
    p.appendBytes((u8*)"/elsewhere", (i32)10);
    p.appendByte((u8)0);
    mkdir(p.bytes(), (u32)$1ED);
    UXData* q = UXData.fromString(p.bytes());
    q.appendBytes((u8*)"/notes.txt", (i32)10);
    q.appendByte((u8)0);
    gDest = q.bytes();

    gAnswer = (i32)1;
    ux_ios_test_call_later((pointer)&user, (i32)1200);
    u8* path = UXSavePanel.run((u8*)"Save the note", (u8*)"", (u8*)"notes.txt");
    Stdio.printf("  (staging: %s)\n", path != (u8*)0 ? path : (u8*)"-");
    ck((u8*)"the panel gives back a path to write", path != (u8*)0);
    ck((u8*)"...the app's own staging file, under the default name", path != (u8*)0 && !sameBytes(path, gDest) && UXFileIO.read(path) != (UXData*)0);
    if (path != (u8*)0)
        {
        ck((u8*)"a write to it succeeds", UXFileIO.write(path, UXData.fromString((u8*)"first draft, héllo")));
        ck((u8*)"...and the bytes are in the chosen document", sameBytes(textOf(gDest), (u8*)"first draft, héllo"));
        ck((u8*)"saving again goes there too", UXFileIO.write(path, UXData.fromString((u8*)"second draft")) && sameBytes(textOf(gDest), (u8*)"second draft"));
        }

    gAnswer = (i32)2;
    ux_ios_test_call_later((pointer)&user, (i32)1200);
    ck((u8*)"cancelling the picker gives nothing", UXSavePanel.run((u8*)"Save another", (u8*)"", (u8*)"other.txt") == (u8*)0);
    ck((u8*)"...and the chosen document is untouched", sameBytes(textOf(gDest), (u8*)"second draft"));
    Stdio.printf(gFails == (i32)0 ? "PASS: UXSavePanel on iOS is the system export picker -- every write reaches the chosen document, a cancel gives nothing\n" : "FAIL: %d\n", gFails);
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
    win.open((u8*)"savepanel", UXGeom.make((i16)0, (i16)0, (i16)sw, (i16)sh), new UXView());
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(win);
    win.displayAll();
    ck((u8*)"iOS has a native save panel", gDriver.hasNativeFileSave());
    ux_ios_test_call_later((pointer)&saves, (i32)300);
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
    }
