// test_win32_pickers.xc — the Win32 colour and font pickers are the real common dialogs (the
// win32-pickers gate): ChooseColor and ChooseFont, run through the driver's pickColor / pickFont.
// A hook (the driver's test slot) answers each REAL dialog as a user would: it types a colour into
// ChooseColor's R/G/B fields, a family and a size into ChooseFont's boxes, and presses OK; then the
// next one is cancelled.  What the user typed must be what the app gets.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWindow.xc"
#import "UXView.xc"

i32 SetDlgItemInt(pointer hwnd, i32 id, u32 v, i32 signed);
pointer SendDlgItemMessageA(pointer hwnd, i32 id, u32 msg, pointer wp, pointer lp);
pointer GetDlgItem(pointer hwnd, i32 id);
pointer SendMessageA(pointer hwnd, u32 msg, pointer wp, pointer lp);
// pick an entry in one of the dialog's lists the way a click does: select it, and tell the dialog
void pickInList(pointer dlg, i32 id, u8* text)
    {
    SendDlgItemMessageA(dlg, id, (u32)$014D, (pointer)(i64)-1, (pointer)text); // CB_SELECTSTRING
    SendMessageA(dlg, (u32)$0111, (pointer)(i64)(((i32)1 << 16) | id), GetDlgItem(dlg, id)); // CBN_SELCHANGE
    }

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

// what the "user" does at the next dialog: 1 type a colour + OK, 2 a font + OK, 3 cancel
i32 gAct;
i32 gSeen;
pointer userAtDialog(pointer hwnd, u32 msg, pointer wp, pointer lp)
    {
    if (msg != (u32)$0110) // WM_INITDIALOG
        {
        return (pointer)0;
        }
    gSeen = gSeen + (i32)1;
    if (gAct == (i32)1)
        {
        SetDlgItemInt(hwnd, (i32)706, (u32)200, (i32)0); // the full dialog's Red, Green, Blue
        SetDlgItemInt(hwnd, (i32)707, (u32)100, (i32)0);
        SetDlgItemInt(hwnd, (i32)708, (u32)50, (i32)0);
        }
    if (gAct == (i32)2)
        {
        pickInList(hwnd, (i32)1136, (u8*)"Tahoma"); // the family list (cmb1)
        pickInList(hwnd, (i32)1138, (u8*)"18");     // the size list (cmb3)
        }
    PostMessageA(hwnd, (u32)$0111, (pointer)(gAct == (i32)3 ? (i32)2 : (i32)1), (pointer)0); // IDOK / IDCANCEL
    return (pointer)0;
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
    win.open((u8*)"pickers", UXGeom.make((i16)40, (i16)40, (i16)320, (i16)200), new UXView());
    gW32TestDialogHook = (pointer)&userAtDialog;
    ck((u8*)"Win32 has native colour and font pickers", d.hasNativeColorPicker() && d.hasNativeFontPicker());

    i32 r = (i32)0;
    i32 g = (i32)0;
    i32 b = (i32)0;
    gAct = (i32)1;
    i32 ok = d.pickColor((i32)0, (i32)0, (i32)255, &r, &g, &b);
    ck((u8*)"ChooseColor ran (its dialog was shown)", gSeen == (i32)1);
    ck((u8*)"...and the colour typed into it is the one returned", ok == (i32)1 && r == (i32)200 && g == (i32)100 && b == (i32)50);
    gAct = (i32)3;
    ck((u8*)"a cancelled colour dialog returns nothing", d.pickColor((i32)1, (i32)2, (i32)3, &r, &g, &b) == (i32)0 && gSeen == (i32)2);

    u8 fam[64];
    i32 size = (i32)0;
    i32 bold = (i32)0;
    i32 ital = (i32)0;
    gAct = (i32)2;
    ok = d.pickFont((u8*)"Arial", (i32)12, (i32)1, (i32)0, &fam[0], (i32)64, &size, &bold, &ital);
    Stdio.printf("  (font: %s %d bold=%d italic=%d)\n", ok == (i32)1 ? &fam[0] : (u8*)"-", size, bold, ital);
    ck((u8*)"ChooseFont ran", gSeen == (i32)3);
    ck((u8*)"...the family and size typed into it are returned", ok == (i32)1 && sameBytes(&fam[0], (u8*)"Tahoma") && size == (i32)18);
    ck((u8*)"...with the weight it was seeded with", bold == (i32)1 && ital == (i32)0);
    gAct = (i32)3;
    ck((u8*)"a cancelled font dialog returns nothing", d.pickFont((u8*)"Arial", (i32)12, (i32)0, (i32)0, &fam[0], (i32)64, &size, &bold, &ital) == (i32)0);

    win.close();
    Stdio.printf(gFails == (i32)0 ? "PASS: Win32 pickers are ChooseColor and ChooseFont -- what the user types is what the app gets\n" : "FAIL: %d\n", gFails);
    }
