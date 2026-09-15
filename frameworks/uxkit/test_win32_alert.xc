// test_win32_alert.xc — modal alerts on the Win32 backend.
//
// UXAlert is now neutral (the model); the driver pops the native dialog.  On Win32 that is a
// MessageBox, whose result maps back to the neutral 1-based button index.  A WH_CBT hook
// dismisses the box deterministically (posting the button command) so the modal call returns
// headlessly — proving the mapping without a human.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXAlert.xc"

i32 gWantId;
pointer gHook;

// Called by Windows when the MessageBox activates — dismiss it with the button we want.
pointer cbtProc(i32 code, pointer wp, pointer lp)
    {
    if (code == (i32)HCBT_ACTIVATE)
        {
        PostMessageA(wp, (u32)WM_COMMAND, (pointer)gWantId, (pointer)0);
        }
    return CallNextHookEx(gHook, code, wp, lp);
    }

i32 ask(i32 wantId, u8* b1, u8* b2, u8* b3)
    {
    UXAlert* al = new UXAlert();
    al.icon = (i32)0;
    al.addLine((u8*)"Discard changes?");
    al.addButton(b1);
    al.addButton(b2);
    if (b3[0] != (u8)0)
        {
        al.addButton(b3);
        }
    gWantId = wantId;
    gHook = SetWindowsHookExA((i32)WH_CBT, (pointer)&cbtProc, (pointer)0, GetCurrentThreadId());
    i32 r = al.runModal();
    UnhookWindowsHookEx(gHook);
    return r;
    }

void main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    d.boot(&sw, &sh);

    i32 a = ask((i32)IDCANCEL, (u8*)"Yes", (u8*)"No", (u8*)""); // 2 btn, dismiss Cancel
    Stdio.printf("2-button dismiss-Cancel -> %d (expect 2)\n", a);
    i32 b = ask((i32)IDOK, (u8*)"Yes", (u8*)"No", (u8*)""); // 2 btn, dismiss OK
    Stdio.printf("2-button dismiss-OK     -> %d (expect 1)\n", b);
    i32 c = ask((i32)IDNO, (u8*)"Save", (u8*)"Discard", (u8*)"Cancel"); // 3 btn, dismiss No
    Stdio.printf("3-button dismiss-No     -> %d (expect 2)\n", c);

    if (a == (i32)2 && b == (i32)1 && c == (i32)2)
        {
        Stdio.printf("PASS: MessageBox result maps to the neutral button index\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
