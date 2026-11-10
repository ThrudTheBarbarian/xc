// showcase_fp_win.xc — the Windows file-chooser portrait: the TOOLKIT panel
// (UXFilePanel, GDI-drawn), run directly; UXOpenPanel itself runs the native
// GetOpenFileName on Windows.  The panel is modal, so a
// thread timer (TIMERPROC, dispatched by the panel's own message pump) fires
// mid-modal: dump the panel window (chrome included) and exit — the capture
// needs no clean return.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWin32.h.xc"
#import "UXOpenPanel.xc"

i32 RedrawWindow(pointer hwnd, pointer rect, pointer rgn, u32 flags);
pointer SetTimer(pointer hwnd, pointer id, u32 ms, pointer proc);
i32 KillTimer(pointer hwnd, pointer id);
pointer GetWindowDC(pointer hwnd);
i32 ReleaseDC(pointer hwnd, pointer hdc);
pointer CreateFileA(u8* name, u32 access, u32 share, pointer sa, u32 disp, u32 flags, pointer tmpl);
i32 WriteFile(pointer h, pointer buf, u32 n, u32* written, pointer ov);
i32 CloseHandle(pointer h);
void ExitProcess(u32 code);
// As showcase_alert_win.xc: the compositor's frame, through PrintWindow(PW_RENDERFULLCONTENT) and
// the extended frame bounds; the window DC under Wine.
typedef i32 DwmGetAttrFn(pointer hwnd, u32 attr, pointer out, u32 size);
i32 PrintWindow(pointer hwnd, pointer hdc, u32 flags);
u32 GetFileAttributesA(u8* name);

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

void timerProc(pointer hwnd, u32 msg, pointer id, u32 ticks)
    {
    KillTimer(hwnd, id);
    pointer pw = gW32Hwnds[(i32)1]; // the panel is the first (only) window
    if (pw == (pointer)0)
        {
        ExitProcess((u32)1);
        }
    RedrawWindow(pw, (pointer)0, (pointer)0, (u32)$181);
    i32 rc[4];
    GetWindowRect(pw, (pointer)&rc[0]);
    i32 x0 = (i32)0;
    i32 y0 = (i32)0;
    i32 ww = rc[2] - rc[0];
    i32 wh = rc[3] - rc[1];
    pointer mem = (pointer)0;
    i32 eb[4];
    DwmGetAttrFn* dwm = (DwmGetAttrFn*)GetProcAddress(LoadLibraryA("dwmapi.dll"), (u8*)"DwmGetWindowAttribute");
    if (dwm != (DwmGetAttrFn*)0 && dwm(pw, (u32)9, (pointer)&eb[0], (u32)16) == (i32)0)
        {
        pointer wdc = GetWindowDC(pw);
        mem = CreateCompatibleDC(wdc);
        SelectObject(mem, CreateCompatibleBitmap(wdc, ww, wh));
        ReleaseDC(pw, wdc);
        if (PrintWindow(pw, mem, (u32)2) != (i32)0) // PW_RENDERFULLCONTENT
            {
            x0 = eb[0] - rc[0];
            y0 = eb[1] - rc[1];
            rc[0] = eb[0];
            rc[1] = eb[1];
            rc[2] = eb[2];
            rc[3] = eb[3];
            }
        }
    i32 w = rc[2] - rc[0];
    i32 h = rc[3] - rc[1];
    if (w <= (i32)0 || h <= (i32)0 || w >= (i32)1200 || h >= (i32)900)
        {
        ExitProcess((u32)1);
        }
    pointer dc = mem != (pointer)0 ? mem : GetWindowDC(pw);
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
            u32 c = GetPixel(dc, x0 + x, y0 + y);
            buf[n] = (u8)(c & (u32)$FF);
            buf[n + (i32)1] = (u8)((c >> (u32)8) & (u32)$FF);
            buf[n + (i32)2] = (u8)((c >> (u32)16) & (u32)$FF);
            n = n + (i32)3;
            }
        }
    if (mem == (pointer)0)
        {
        ReleaseDC(pw, dc);
        }
    pointer f = CreateFileA((u8*)"ux-fp-win.ppm", (u32)$40000000, (u32)0, (pointer)0,
                            (u32)2, (u32)$80, (pointer)0);
    u32 wrote = (u32)0;
    WriteFile(f, (pointer)buf, (u32)n, &wrote, (pointer)0);
    CloseHandle(f);
    Stdio.printf("PASS: panel shot\n");
    ExitProcess((u32)0);
    }

void main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    d.boot(&sw, &sh);
    SetTimer((pointer)0, (pointer)7, (u32)400, (pointer)&timerProc); // thread timer: fires in the panel's pump
    // the demo folder: C:\ux_fp_demo on a Windows machine (capture.sh makes it), else the Mac's
    // /tmp/ux_fp_demo as Wine sees it
    u8* dir = (u8*)"C:\\ux_fp_demo";
    if (GetFileAttributesA(dir) == (u32)$FFFFFFFF)
        {
        dir = (u8*)"Z:\\tmp\\ux_fp_demo";
        }
    UXOpenPanel.runToolkit((u8*)"Open", dir);
    Stdio.printf("FAIL: panel returned before the shot\n");
    }
