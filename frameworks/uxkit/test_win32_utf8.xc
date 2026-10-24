// test_win32_utf8.xc — UTF-8 text reaches Windows as UTF-16 (the win32-utf8 gate, under Wine): a
// window title, a native button, a combo box item and a menu item keep "160×160 → ✓" exactly, read
// back from the real controls, and "×" measures as one glyph, not as the two ANSI characters "Ã—"
// its bytes would be in the code page.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"

i32 GetMenuStringW(pointer menu, u32 item, pointer ws, i32 cap, u32 flags);
#define CB_GETLBTEXT_ $0148

#define UTF8_TEXT "160×160 → ✓" // 160×160 → ✓

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
    if (a[i] != b[i])
        {
        Stdio.printf("    got \"%s\"\n", a);
        }
    return a[i] == b[i];
    }
// UTF-16 read back from Windows, as UTF-8
bool wideIs(u16* w, i32 n, u8* want)
    {
    u8 got[256];
    i32 len = WideCharToMultiByte((u32)CP_UTF8, (u32)0, (pointer)w, n, (pointer)&got[0], (i32)255, (pointer)0, (pointer)0);
    got[len > (i32)0 ? len : (i32)0] = (u8)0;
    return sameBytes(&got[0], want);
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
    win.open((u8*)UTF8_TEXT, UXGeom.make((i16)40, (i16)40, (i16)300, (i16)200), new UXView());
    pointer hwnd = gW32Hwnds[win.handle];
    u8 buf[256];
    u16 wb[256];
    i32 wn = InternalGetWindowText(hwnd, (pointer)&wb[0], (i32)256); // the title the caption shows
    ck((u8*)"the window title", wideIs(&wb[0], wn, (u8*)UTF8_TEXT));

    pointer btn = w32Create((u32)0, (pointer) "BUTTON", (pointer)UTF8_TEXT, (u32)WS_CHILD | (u32)BS_PUSHBUTTON,
                            (i32)10, (i32)10, (i32)200, (i32)24, hwnd, (pointer)0, gW32Inst, (pointer)0);
    w32GetText(btn, &buf[0], (i32)256);
    ck((u8*)"a native button's label", sameBytes(&buf[0], (u8*)UTF8_TEXT));
    w32SetText(btn, (u8*)"×");
    w32GetText(btn, &buf[0], (i32)256);
    ck((u8*)"...set again", sameBytes(&buf[0], (u8*)"×"));
    w32GetText(btn, &buf[0], (i32)4); // "×" is 2 bytes: a 4-byte buffer holds it; 2 would not
    ck((u8*)"a read into a small buffer", sameBytes(&buf[0], (u8*)"×"));
    w32GetText(btn, &buf[0], (i32)2);
    ck((u8*)"...cut at a character, never inside one", buf[0] == (u8)0);

    pointer cb = w32Create((u32)0, (pointer) "COMBOBOX", (pointer) "", (u32)WS_CHILD | (u32)CBS_DROPDOWNLIST,
                           (i32)10, (i32)40, (i32)200, (i32)120, hwnd, (pointer)0, gW32Inst, (pointer)0);
    w32Send(cb, (u32)CB_ADDSTRING, (pointer)0, (u8*)UTF8_TEXT);
    wn = (i32)SendMessageW(cb, (u32)CB_GETLBTEXT_, (pointer)0, (pointer)&wb[0]);
    ck((u8*)"a combo box item", wideIs(&wb[0], wn, (u8*)UTF8_TEXT));

    pointer menu = CreatePopupMenu();
    w32AppendMenu(menu, (u32)0, (pointer)1, (u8*)UTF8_TEXT);
    wn = GetMenuStringW(menu, (u32)1, (pointer)&wb[0], (i32)256, (u32)0);
    ck((u8*)"a menu item", wideIs(&wb[0], wn, (u8*)UTF8_TEXT));

    i32 one = d.textWidth((u8*)"×", (i32)0);       // ×
    i32 two = d.textWidth((u8*)"Ã—", (i32)0); // Ã—, what its bytes are in cp1252
    Stdio.printf("    width: x-sign %d, the two ANSI characters %d\n", one, two);
    ck((u8*)"\"x-sign\" measures as one glyph", one > (i32)0 && one < two);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UTF-8 text reaches Windows as UTF-16\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
