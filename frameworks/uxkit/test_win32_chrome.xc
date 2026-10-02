// test_win32_chrome.xc — a window's chrome on Windows (the win32-chrome gate, under Wine): Windows
// has one title, so UXKit's title, subtitle and modified flag are composed into it the Windows way
// ("*Notes - draft"); and a window's icon is its document's own shell icon (WM_SETICON), falling
// back to the app's when there is no document.  Read back from the real HWND.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"

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
// the HWND's title, as Windows has it, against an ASCII expectation
bool titleIs(UXWindow* w, u8* want)
    {
    u16 buf[256];
    i32 n = GetWindowTextW(gW32Hwnds[w.handle], (pointer)&buf[0], (i32)256);
    i32 i = (i32)0;
    while (i < n && want[i] != (u8)0 && (u16)want[i] == buf[i])
        {
        i = i + (i32)1;
        }
    bool same = i == n && want[i] == (u8)0;
    if (!same)
        {
        u8 got[256];
        for (i32 k = (i32)0; k < n && k < (i32)255; k = k + (i32)1)
            {
            got[k] = (u8)buf[k];
            }
        got[n < (i32)255 ? n : (i32)255] = (u8)0;
        Stdio.printf("    title is \"%s\"\n", &got[(i32)0]);
        }
    return same;
    }
pointer iconOf(UXWindow* w, i32 which)
    {
    return SendMessageA(gW32Hwnds[w.handle], (u32)WM_GETICON, (pointer)which, (pointer)0);
    }

void main(void)
    {
    gFails = (i32)0;
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display\n");
        return;
        }
    UXWindow* win = new UXWindow();
    win.open((u8*)"Notes", UXGeom.make((i16)40, (i16)40, (i16)300, (i16)200), new UXView());
    ck((u8*)"the title", titleIs(win, (u8*)"Notes"));
    win.setSubtitle((u8*)"draft");
    ck((u8*)"a subtitle goes after a dash", titleIs(win, (u8*)"Notes - draft"));
    win.setModified(true);
    ck((u8*)"unsaved changes put a * in front", titleIs(win, (u8*)"*Notes - draft"));
    win.setTitle((u8*)"Letter");
    ck((u8*)"...which survives a new title", titleIs(win, (u8*)"*Letter - draft"));
    win.setModified(false);
    win.setSubtitle((u8*)"");
    ck((u8*)"and all comes off again", titleIs(win, (u8*)"Letter"));

    ck((u8*)"no document icon to start with", iconOf(win, (i32)ICON_BIG) == (pointer)0);
    win.setIcon((u8*)"C:\\windows\\notepad.exe");
    pointer big = iconOf(win, (i32)ICON_BIG);
    ck((u8*)"a document's path gives the window its shell icon", big != (pointer)0 && iconOf(win, (i32)ICON_SMALL) != (pointer)0);
    win.setIcon((u8*)"");
    ck((u8*)"no document: back to the app's icon (none here)", iconOf(win, (i32)ICON_BIG) == (pointer)0);
    win.close();
    Stdio.printf(gFails == (i32)0 ? "PASS: Windows window chrome -- composed title, modified star, document icon\n" : "FAIL: %d\n", gFails);
    }
