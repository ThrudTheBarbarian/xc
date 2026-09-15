// showcase_win2.xc — SHEET 2 (containers + navigation) of the Windows contact sheet: one window, every widget (real
// BUTTON/EDIT/msctls children where they exist), ONE PrintWindow capture and
// dump; capture.sh crops.  Runs under Wine, whose classic-Windows widget art
// IS the platform look.  The PPM is written with the Win32 file API — win64
// has no Files.xc, and the capture tool belongs to its platform anyway.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWindow.xc"
#import "UXWin32.h.xc"
#import "showcase_widgets.xc"

// Not in UXWin32.h.xc (capture-only surface): the window-render + file API.
i32 RedrawWindow(pointer hwnd, pointer rect, pointer rgn, u32 flags);
pointer CreateFileA(u8* name, u32 access, u32 share, pointer sa, u32 disp, u32 flags, pointer tmpl);
i32 WriteFile(pointer h, pointer buf, u32 n, u32* written, pointer ov);
i32 CloseHandle(pointer h);

#define SHEET_W 440
#define SHEET_H 630

void main(void)
    {
    gDriver = new UXWin32Driver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("FAIL: boot\n");
        return;
        }

    UXView* content = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"sheet", UXGeom.make(0, 60, (i16)SHEET_W, (i16)SHEET_H), content);
    buildSheet2(content);
    win.tree.finalise();
    win.displayAll();
    // force the first paint through — CHILDREN included (an UpdateWindow on
    // the parent alone leaves child update regions unpainted)
    RedrawWindow(gW32Hwnds[(i32)1], (pointer)0, (pointer)0, (u32)$181); // INVALIDATE|ALLCHILDREN|UPDATENOW

    // Read the painted client area straight off the window DC: Wine's
    // PrintWindow renders children only partially, but the client DC holds
    // what actually painted — the platform look as the user sees it.
    pointer mdc = GetDC(gW32Hwnds[(i32)1]);

    // P6 PPM via the Win32 file API (GetPixel COLORREF is 0x00BBGGRR).
    u8* buf = (u8*)malloc((u32)(SHEET_W * SHEET_H * 3 + 32));
    i32 n = (i32)0;
    u8* hdr = (u8*)"P6\n440 630\n255\n"; // widths are the sheet's constants
    for (i32 i = (i32)0; hdr[i] != (u8)0; i++)
        {
        buf[n] = hdr[i];
        n = n + (i32)1;
        }
    for (i32 y = (i32)0; y < (i32)SHEET_H; y++)
        {
        for (i32 x = (i32)0; x < (i32)SHEET_W; x++)
            {
            u32 c = GetPixel(mdc, x, y);
            buf[n] = (u8)(c & (u32)$FF); // R (low byte of COLORREF)
            buf[n + (i32)1] = (u8)((c >> (u32)8) & (u32)$FF);
            buf[n + (i32)2] = (u8)((c >> (u32)16) & (u32)$FF);
            n = n + (i32)3;
            }
        }
    pointer f = CreateFileA((u8*)"ux-sheet2-win.ppm", (u32)$40000000, (u32)0, (pointer)0,
                            (u32)2 /*CREATE_ALWAYS*/, (u32)$80, (pointer)0);
    u32 wrote = (u32)0;
    WriteFile(f, (pointer)buf, (u32)n, &wrote, (pointer)0);
    CloseHandle(f);
    Stdio.printf(wrote == (u32)n ? "PASS: sheet shot\n" : "FAIL: short write\n");
    }
