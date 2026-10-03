// test_win32_files.xc — the Win32 open and save panels are the real common dialogs (the win32-files
// gate): GetOpenFileName and GetSaveFileName, run through UXOpenPanel and UXSavePanel.  A hook (the
// driver's test slot) answers each REAL dialog as a user would: once the dialog is up it reads the
// name box, types a path into it and presses OK, or presses Cancel.  What the user typed must be what
// the app gets, and the file it names must read and write through UXFileIO.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXOpenPanel.xc"
#import "UXSavePanel.xc"
#import "UXFileIO.xc"

pointer GetParent(pointer hwnd);
i32 SetDlgItemTextA(pointer hwnd, i32 id, u8* text);
i32 EnumThreadWindows(u32 thread, pointer fn, pointer lp);
u32 GetCurrentDirectoryA(u32 n, u8* buf);
pointer SetTimer(pointer hwnd, pointer id, u32 ms, pointer fn);
i32 KillTimer(pointer hwnd, pointer id);
i32 IsWindowVisible(pointer hwnd);

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
// a + b into out
void join(u8* out, u8* a, u8* b)
    {
    i32 n = (i32)0;
    i32 i = (i32)0;
    while (a[i] != (u8)0)
        {
        out[n] = a[i];
        n = n + (i32)1;
        i = i + (i32)1;
        }
    i = (i32)0;
    while (b[i] != (u8)0)
        {
        out[n] = b[i];
        n = n + (i32)1;
        i = i + (i32)1;
        }
    out[n] = (u8)0;
    }

// what the "user" does at the next dialog, a moment after it is up: type gType into the name box and
// press OK, or (gType empty) press Cancel.  What the name box held then is kept in gSeenName.
u8 gType[600];
u8 gSeenName[600];
i32 gSeen;
pointer userAtDialog(pointer hwnd, u32 msg, pointer wp, pointer lp)
    {
    if (msg == (u32)$004E) // WM_NOTIFY
        {
        u32* code = (u32*)((u8*)lp + (i64)16); // OFNOTIFY.hdr.code
        if (code[0] == (u32)$FFFFFDA7) // CDN_INITDONE: the dialog is up; act a moment later, as a person
            {                          // would (Windows 10 fills the name box after this notification)
            SetTimer(hwnd, (pointer)(i64)7, (u32)300, (pointer)0);
            }
        return (pointer)0;
        }
    if (msg != (u32)$0113 || wp != (pointer)(i64)7) // WM_TIMER, ours
        {
        return (pointer)0;
        }
    KillTimer(hwnd, (pointer)(i64)7);
    gSeen = gSeen + (i32)1;
    pointer dlg = GetParent(hwnd); // an Explorer-style hook is a child of the dialog
    gSeenName[0] = (u8)0;
    SendMessageA(dlg, (u32)$0464, (pointer)(i64)600, (pointer)&gSeenName[0]); // CDM_GETSPEC: the name box's text
    if (gType[0] != (u8)0)
        {
        SetDlgItemTextA(dlg, (i32)$047C, &gType[0]);
        SetDlgItemTextA(dlg, (i32)$0480, &gType[0]);
        }
    PostMessageA(dlg, (u32)$0111, (pointer)(gType[0] != (u8)0 ? (i32)1 : (i32)2), (pointer)0); // IDOK / IDCANCEL
    return (pointer)0;
    }

// With no hook, as in an app: a timer looks for the dialog among this thread's windows (any dialog
// window, visible, with the prompt as its title -- the modern dialog Windows shows without a hook is
// one too), and cancels it.
i32 gFoundPlain;
i32 lookAtWindow(pointer hwnd, pointer lp)
    {
    u8 cls[16];
    u8 title[64];
    GetClassNameA(hwnd, (pointer)&cls[0], (i32)16);
    GetWindowTextA(hwnd, (pointer)&title[0], (i32)64);
    if (sameBytes(&cls[0], (u8*)"#32770") && sameBytes(&title[0], (u8*)"Open without a hook") && IsWindowVisible(hwnd) != (i32)0)
        {
        gFoundPlain = gFoundPlain + (i32)1;
        PostMessageA(hwnd, (u32)$0111, (pointer)(i32)2, (pointer)0); // IDCANCEL
        }
    return (i32)1;
    }
void lookForPlainDialog(pointer hwnd, u32 msg, pointer id, u32 ms)
    {
    EnumThreadWindows(GetCurrentThreadId(), (pointer)&lookAtWindow, (pointer)0);
    }

void main(void)
    {
    gFails = (i32)0;
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    d.boot(&sw, &sh);
    UXWindow* win = new UXWindow();
    win.open((u8*)"files", UXGeom.make((i16)40, (i16)40, (i16)320, (i16)200), new UXView());
    gW32TestDialogHook = (pointer)&userAtDialog;
    ck((u8*)"Win32 has native open and save panels", d.hasNativeFileOpen() && d.hasNativeFileSave());

    u8 cwd[400];
    GetCurrentDirectoryA((u32)400, &cwd[0]);
    u8 picked[600];
    join(&picked[0], &cwd[0], (u8*)"\\pick.txt");
    ck((u8*)"a file to open", UXFileIO.write(&picked[0], UXData.fromString((u8*)"opened through GetOpenFileName")));

    // open: the user types the file's path and presses Open
    join(&gType[0], &picked[0], (u8*)"");
    u8* got = UXOpenPanel.run((u8*)"Open a file", &cwd[0]);
    Stdio.printf("  (open: %s)\n", got != (u8*)0 ? got : (u8*)"-");
    ck((u8*)"GetOpenFileName ran (its dialog was shown)", gSeen == (i32)1);
    ck((u8*)"...and the path typed into it is the one returned", got != (u8*)0 && sameBytes(got, &picked[0]));
    UXData* data = got != (u8*)0 ? UXFileIO.read(got) : (UXData*)0;
    ck((u8*)"...which reads back through UXFileIO", data != (UXData*)0 && data.length() == (i32)30);
    gType[0] = (u8)0;
    ck((u8*)"a cancelled open returns nothing", UXOpenPanel.run((u8*)"Open a file", &cwd[0]) == (u8*)0 && gSeen == (i32)2);

    // save: the name box starts with the default name; the user types a new path and presses Save
    u8 saved[600];
    join(&saved[0], &cwd[0], (u8*)"\\saved.txt");
    remove(&saved[0]); // a file left by an earlier run would make the dialog ask about replacing it
    join(&gType[0], &saved[0], (u8*)"");
    got = UXSavePanel.run((u8*)"Save the file", &cwd[0], (u8*)"untitled.txt");
    Stdio.printf("  (save: %s, name box was \"%s\")\n", got != (u8*)0 ? got : (u8*)"-", &gSeenName[0]);
    ck((u8*)"GetSaveFileName ran", gSeen == (i32)3);
    ck((u8*)"...starting with the default name", sameBytes(&gSeenName[0], (u8*)"untitled.txt"));
    ck((u8*)"...and the path typed into it is the one returned", got != (u8*)0 && sameBytes(got, &saved[0]));
    ck((u8*)"...which writes through UXFileIO", got != (u8*)0 && UXFileIO.write(got, UXData.fromString((u8*)"saved")));
    data = UXFileIO.read(&saved[0]);
    ck((u8*)"...and reads back", data != (UXData*)0 && data.length() == (i32)5);
    gType[0] = (u8)0;
    ck((u8*)"a cancelled save returns nothing", UXSavePanel.run((u8*)"Save the file", &cwd[0], (u8*)"untitled.txt") == (u8*)0 && gSeen == (i32)4);

    // and with no hook at all, the dialog an app gets is on screen
    gW32TestDialogHook = (pointer)0;
    gFoundPlain = (i32)0;
    pointer t = SetTimer((pointer)0, (pointer)0, (u32)200, (pointer)&lookForPlainDialog);
    ck((u8*)"the plain dialog (no hook) is shown, and cancels", UXOpenPanel.run((u8*)"Open without a hook", &cwd[0]) == (u8*)0 && gFoundPlain >= (i32)1);
    KillTimer((pointer)0, t);

    win.close();
    Stdio.printf(gFails == (i32)0 ? "PASS: Win32 open and save are GetOpenFileName and GetSaveFileName -- what the user types is what the app gets\n" : "FAIL: %d\n", gFails);
    }
