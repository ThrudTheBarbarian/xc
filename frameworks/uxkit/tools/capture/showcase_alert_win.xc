// showcase_alert_win.xc — the Windows alert portrait: the driver's REAL
// MessageBox, photographed from inside the WH_CBT hook that the alert gate
// (test_win32_alert) already uses to dismiss it.  On HCBT_ACTIVATE the box
// exists and has painted enough to force: redraw synchronously, read the
// WHOLE window (chrome included) off its window DC, write the PPM, then
// post the dismissal so runModal returns headlessly.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXAlert.xc"

// Capture-only surface (not in UXWin32.h.xc).
i32 RedrawWindow(pointer hwnd, pointer rect, pointer rgn, u32 flags);
pointer SetTimer(pointer hwnd, pointer id, u32 ms, pointer proc);
i32 KillTimer(pointer hwnd, pointer id);
pointer GetWindowDC(pointer hwnd);
i32 ReleaseDC(pointer hwnd, pointer hdc);
pointer CreateFileA(u8* name, u32 access, u32 share, pointer sa, u32 disp, u32 flags, pointer tmpl);
i32 WriteFile(pointer h, pointer buf, u32 n, u32* written, pointer ov);
i32 CloseHandle(pointer h);

pointer gHook;
i32 gShot;

// Decimal digits of v into out (no NUL); returns the digit count.  v < 10000.
i32 putDec(u8* out, i32 v)
    {
    u8 tmp[8];
    i32 t = (i32)0;
    if (v <= (i32)0)
        {
        out[0] = (u8)48;
        return (i32)1;
        }
    while (v > (i32)0)
        {
        tmp[t] = (u8)((i32)48 + v % (i32)10);
        v = v / (i32)10;
        t = t + (i32)1;
        }
    for (i32 i = (i32)0; i < t; i++)
        {
        out[i] = tmp[t - (i32)1 - i];
        }
    return t;
    }

// Runs INSIDE the MessageBox's modal loop (SetTimer with a TIMERPROC), so by
// now the box is shown and painted — photograph it, then dismiss.
void timerProc(pointer hwnd, u32 msg, pointer id, u32 ticks)
    {
    KillTimer(hwnd, id);
    if (gShot != (i32)0)
        {
        return;
        }
    gShot = (i32)1;
    RedrawWindow(hwnd, (pointer)0, (pointer)0, (u32)$181); // INVALIDATE|ALLCHILDREN|UPDATENOW
    i32 rc[4];
    GetWindowRect(hwnd, (pointer)&rc[0]);
    i32 w = rc[2] - rc[0];
    i32 h = rc[3] - rc[1];
    if (w > (i32)0 && h > (i32)0 && w < (i32)1200 && h < (i32)800)
        {
        pointer dc = GetWindowDC(hwnd);
        u8* buf = (u8*)malloc((u32)(w * h * 3 + 64));
        i32 n = (i32)0;
        buf[n] = (u8)80;
        buf[n + (i32)1] = (u8)54;
        buf[n + (i32)2] = (u8)10;
        n = n + (i32)3; // "P6\n"
        n = n + putDec(&buf[n], w);
        buf[n] = (u8)32;
        n = n + (i32)1;
        n = n + putDec(&buf[n], h);
        buf[n] = (u8)10;
        n = n + (i32)1;
        buf[n] = (u8)50;
        buf[n + (i32)1] = (u8)53;
        buf[n + (i32)2] = (u8)53;
        buf[n + (i32)3] = (u8)10;
        n = n + (i32)4; // "255\n"
        for (i32 y = (i32)0; y < h; y++)
            {
            for (i32 x = (i32)0; x < w; x++)
                {
                u32 c = GetPixel(dc, x, y);
                buf[n] = (u8)(c & (u32)$FF);
                buf[n + (i32)1] = (u8)((c >> (u32)8) & (u32)$FF);
                buf[n + (i32)2] = (u8)((c >> (u32)16) & (u32)$FF);
                n = n + (i32)3;
                }
            }
        ReleaseDC(hwnd, dc);
        pointer f = CreateFileA((u8*)"ux-alert-win.ppm", (u32)$40000000, (u32)0, (pointer)0,
                                (u32)2, (u32)$80, (pointer)0);
        u32 wrote = (u32)0;
        WriteFile(f, (pointer)buf, (u32)n, &wrote, (pointer)0);
        CloseHandle(f);
        }
    PostMessageA(hwnd, (u32)WM_COMMAND, (pointer)IDOK, (pointer)0);
    }

pointer cbtProc(i32 code, pointer wp, pointer lp)
    {
    if (code == (i32)HCBT_ACTIVATE)
        {
        SetTimer(wp, (pointer)7, (u32)250, (pointer)&timerProc); // fire once the modal loop pumps
        }
    return CallNextHookEx(gHook, code, wp, lp);
    }

void main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    d.boot(&sw, &sh);

    UXAlert* al = new UXAlert();
    al.icon = (i32)3; // stop -> MB_ICONSTOP
    al.addLine((u8*)"Save changes to Rocks.doc?");
    al.addLine((u8*)"Your edits will be lost otherwise.");
    al.addButton((u8*)"Save");
    al.addButton((u8*)"Cancel");
    gShot = (i32)0;
    gHook = SetWindowsHookExA((i32)WH_CBT, (pointer)&cbtProc, (pointer)0, GetCurrentThreadId());
    al.runModal();
    UnhookWindowsHookEx(gHook);
    Stdio.printf(gShot != (i32)0 ? "PASS: alert shot\n" : "FAIL: no activate\n");
    }
