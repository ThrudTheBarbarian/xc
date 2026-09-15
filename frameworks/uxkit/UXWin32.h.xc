// UXWin32.h.xc — the Win32 / GDI entry points the Win32 backend calls, in one place.
// The GEM backend has UXGem.h.xc; this is its opposite number.  Plain C-ABI externs — xtc
// emits the Win64 ABI, so these bind directly (proven by tests/interop, and by test_win32).

struct WNDCLASSA
    {
    u32 style;
    u32 _p0;
    pointer lpfnWndProc;
    i32 cbClsExtra;
    i32 cbWndExtra;
    pointer hInstance;
    pointer hIcon;
    pointer hCursor;
    pointer hbrBackground;
    pointer lpszMenuName;
    pointer lpszClassName;
    } struct MSG
    {
    pointer hwnd;
    u32 message;
    u32 _p;
    pointer wParam;
    pointer lParam;
    u32 time;
    i32 ptx;
    i32 pty;
    u32 _p2;
    } struct RECT
    {
    i32 left;
    i32 top;
    i32 right;
    i32 bottom;
    } struct PAINTSTRUCT
    {
    pointer hdc;
    i32 fErase;
    i32 _p;
    i32 rl;
    i32 rt;
    i32 rr;
    i32 rb;
    i32 fRestore;
    i32 fInc;
    pointer r0;
    pointer r1;
    pointer r2;
    pointer r3;
    } struct POINT
    {
    i32 x;
    i32 y;
    // GetTextExtentPoint32A's answer
    } struct SIZE
    {
    i32 cx;
    i32 cy;
    }

    pointer GetModuleHandleA(pointer name);
u16 RegisterClassA(pointer wc);
pointer CreateWindowExA(u32 ex, pointer cls, pointer name, u32 style,
                        i32 x, i32 y, i32 w, i32 h, pointer par, pointer menu, pointer inst, pointer p);
pointer DefWindowProcA(pointer hwnd, u32 msg, pointer wp, pointer lp);
i32 ShowWindow(pointer hwnd, i32 cmd);
i32 PostMessageA(pointer hwnd, u32 msg, pointer wp, pointer lp);
pointer GetDlgItem(pointer hwnd, i32 id); // a child by its control id (W32_CTRL_ID_BASE + node index)
pointer GetParent(pointer hwnd);          // a child's owning window (the scroll container's canvas)
i32 DestroyWindow(pointer hwnd);
void PostQuitMessage(i32 code);
i32 GetMessageA(pointer msg, pointer hwnd, u32 mn, u32 mx);
i32 PeekMessageA(pointer msg, pointer hwnd, u32 mn, u32 mx, u32 remove);
i32 TranslateMessage(pointer msg);
pointer DispatchMessageA(pointer msg);
pointer SetWindowLongPtrA(pointer hwnd, i32 idx, pointer v);
pointer GetWindowLongPtrA(pointer hwnd, i32 idx);
i32 InvalidateRect(pointer hwnd, pointer r, i32 erase);
i32 UpdateWindow(pointer hwnd);
i32 EnableWindow(pointer hwnd, i32 enable);
i32 GetClientRect(pointer hwnd, pointer r);
i32 GetWindowRect(pointer hwnd, pointer r);            // on-screen rect (Wine desktop = Mac screen px)
i32 AdjustWindowRect(pointer r, u32 style, i32 bMenu); // client size -> outer window size
u32 SetBkColor(pointer hdc, u32 color);
#define WM_CTLCOLOREDIT $0133
#define WM_CTLCOLORBTN $0135
#define WM_CTLCOLORSTATIC $0138
#define COLOR_BTNFACE 15
i32 SetWindowTextA(pointer hwnd, pointer s);
i32 SetWindowTextW(pointer hwnd, pointer ws); // wide title (UTF-16)

// The neutral toolkit's strings are UTF-8; the ...A text APIs treat bytes as the ANSI code page and
// mangle every multibyte char (an em dash renders as "â€""), so text goes out via the wide (...W) APIs
// after MultiByteToWideChar(CP_UTF8).  CreateWindowExA is fine (the class/placeholder names are ASCII).
#define CP_UTF8 65001
i32 MultiByteToWideChar(u32 cp, u32 flags, pointer mb, i32 cb, pointer wc, i32 cch);

// GDI
pointer BeginPaint(pointer hwnd, pointer ps);
i32 EndPaint(pointer hwnd, pointer ps);
i32 FillRect(pointer hdc, pointer r, pointer br);
pointer CreateSolidBrush(u32 color);
i32 DeleteObject(pointer o);
u32 SetTextColor(pointer hdc, u32 color);
i32 SetBkMode(pointer hdc, i32 mode);
i32 TextOutA(pointer hdc, i32 x, i32 y, pointer s, i32 n);
i32 TextOutW(pointer hdc, i32 x, i32 y, pointer ws, i32 n); // wide text (UTF-16)
i32 Polygon(pointer hdc, pointer pts, i32 n);
i32 FrameRect(pointer hdc, pointer r, pointer br);
// The 3D bevels that make Win32 controls read as Windows: raised for a button, sunken for a field or
// list box.  DrawEdge does not modify the rect; it draws the border just inside it.
i32 DrawEdge(pointer hdc, pointer r, u32 edge, u32 flags);
#define EDGE_RAISED $0005 // BDR_RAISEDOUTER | BDR_RAISEDINNER
#define EDGE_SUNKEN $000A // BDR_SUNKENOUTER | BDR_SUNKENINNER
#define BF_RECT $000F     // all four sides
pointer SelectObject(pointer hdc, pointer o);
pointer GetStockObject(i32 which);
// A sized font for custom-drawn text (drawText's size argument).  Negative cHeight requests a character
// (em) height; the rest are defaults (weight 400, no italic, default charset/precision/quality/pitch,
// empty face = let GDI pick).  Select it, draw, then restore + DeleteObject.
pointer CreateFontA(i32 cHeight, i32 cWidth, i32 esc, i32 orient, i32 weight,
                    u32 italic, u32 underline, u32 strike, u32 charset,
                    u32 outPrec, u32 clipPrec, u32 quality, u32 pitch, u8* face);

// Menus.  A menu bar is a per-window HMENU; Windows sends WM_COMMAND(id) when an item fires.
pointer CreateMenu(void);
pointer CreatePopupMenu(void);
i32 AppendMenuA(pointer menu, u32 flags, pointer idOrSubmenu, pointer text);
i32 SetMenu(pointer hwnd, pointer menu);
i32 DrawMenuBar(pointer hwnd);
i32 CheckMenuItem(pointer menu, u32 id, u32 how);
i32 EnableMenuItem(pointer menu, u32 id, u32 how);

// A modal alert.  MessageBox shows OK/Cancel/Yes/No; the driver maps the result back to the
// neutral 1-based button index.  (MessageBoxA itself comes from the win64 Platform lib.)  The
// CBT hook lets a headless test dismiss it deterministically.
pointer SetWindowsHookExA(i32 id, pointer fn, pointer mod, u32 tid);
i32 UnhookWindowsHookEx(pointer h);
pointer CallNextHookEx(pointer h, i32 code, pointer wp, pointer lp);
u32 GetCurrentThreadId(void);

// Scrolling: the native scrollbar owns the thumb/track/arrows and posts WM_VSCROLL; the driver
// keeps the offset, which the neutral layoutFor subtracts (so the whole tree — and hit-testing —
// scrolls for free, exactly as on GEM).
i32 SetScrollRange(pointer hwnd, i32 bar, i32 lo, i32 hi, i32 redraw);
i32 SetScrollPos(pointer hwnd, i32 bar, i32 pos, i32 redraw);
i32 GetScrollPos(pointer hwnd, i32 bar);

#define GWLP_USERDATA (-21)
#define WM_DESTROY $0002
#define WM_CLOSE $0010
#define WM_SYSCOMMAND $0112 // the frame's own commands; SC_CLOSE is the close box
#define SC_CLOSE $F060
#define WM_QUIT $0012
#define WM_PAINT $000F
#define WM_ERASEBKGND $0014
#define WM_LBUTTONDOWN $0201
#define WM_KEYDOWN $0100
#define WM_CHAR $0102
#define PM_REMOVE $0001
#define WM_COMMAND $0111
#define WS_OVERLAPPEDWINDOW $00CF0000
#define SW_SHOW 5

// ---- native child controls (the "look like Windows" path) -------------------------------------
// realizeTree mints a real BUTTON/EDIT/STATIC HWND per control node so the OS draws it (and tracks
// its look-and-feel), instead of the driver hand-painting a grey box.  WM_COMMAND from a control is
// turned into a synthetic click at the control's centre, routed through the neutral hit-test — the
// same trick the AppKit shim uses — so the toolkit's target/action fires unchanged.
pointer SendMessageA(pointer hwnd, u32 msg, pointer wp, pointer lp);
i32 MoveWindow(pointer hwnd, i32 x, i32 y, i32 w, i32 h, i32 repaint);
i32 GetWindowTextA(pointer hwnd, pointer buf, i32 n); // read an EDIT's text back to the model
i32 ScreenToClient(pointer hwnd, pointer pt);         // control centre -> parent client coords
i32 GetAsyncKeyState(i32 vk);                         // hi bit = key currently down (real-time)
i32 GetCursorPos(pointer pt);                         // cursor in SCREEN coords
pointer FindWindowA(pointer cls, pointer title);      // another process's window, by class/title
pointer GetActiveWindow(void);                        // this thread's active top-level window
void Sleep(u32 ms);
// The wall clock, already broken down in UTC — no 64-bit arithmetic, which xt has no type for.
struct SYSTEMTIME
    {
    u16 year;
    u16 month;
    u16 dayOfWeek;
    u16 day;
    u16 hour;
    u16 minute;
    u16 second;
    u16 millis;
    } void GetSystemTime(pointer st);
// Local time as well, so the difference gives the offset in force (DST included) with no tz struct.
void GetLocalTime(pointer st);
// The profile (.ini) API, which IS a (section, key) -> string store with the read-modify-write of a
// single key already done for us — so persistent settings need no file parsing of our own.  Passing
// a null value DELETES the key.  Ancient, and still the shortest honest way to keep a preference in
// a file the user can read; Wine implements it faithfully.
i32 WritePrivateProfileStringA(pointer section, pointer key, pointer value, pointer file);
i32 GetPrivateProfileStringA(pointer section, pointer key, pointer deflt, pointer out, i32 cap, pointer file);
u32 GetEnvironmentVariableA(pointer name, pointer out, u32 cap); // %APPDATA% for the settings path
i32 CreateDirectoryA(pointer path, pointer sec);                 // make it on first run
#define VK_LBUTTON $01
i32 SetWindowPos(pointer hwnd, pointer after, i32 x, i32 y, i32 w, i32 h, u32 flags);
i32 BringWindowToTop(pointer hwnd);
i32 SetForegroundWindow(pointer hwnd);

// ---- the common file-open dialog (comdlg32) --------------------------------------------------
// OPENFILENAMEA, hand-padded to the Win64 C layout (xtc packs, so pointer-alignment gaps are explicit).
#import <comdlg32>
struct OPENFILENAMEA
    {
    u32 lStructSize;
    u32 _p0;
    pointer hwndOwner;
    pointer hInstance;
    pointer lpstrFilter;
    pointer lpstrCustomFilter;
    u32 nMaxCustFilter;
    u32 nFilterIndex;
    pointer lpstrFile;
    u32 nMaxFile;
    u32 _p1;
    pointer lpstrFileTitle;
    u32 nMaxFileTitle;
    u32 _p2;
    pointer lpstrInitialDir;
    pointer lpstrTitle;
    u32 Flags;
    u16 nFileOffset;
    u16 nFileExtension;
    pointer lpstrDefExt;
    pointer lCustData;
    pointer lpfnHook;
    pointer lpTemplateName;
    pointer pvReserved;
    u32 dwReserved;
    u32 FlagsEx;
    } i32 GetOpenFileNameA(pointer ofn); // nonzero if the user picked a file
#define OFN_HIDEREADONLY $0004
#define OFN_PATHMUSTEXIST $0800
#define OFN_FILEMUSTEXIST $1000
// The shell file dialog needs the calling thread in a COM apartment, or it faults on some hosts.
#import <ole32>
i32 OleInitialize(pointer reserved);
void OleUninitialize(void);

// ---- directory listing (kernel32) — for the toolkit file panel under Wine, where the native dialog hangs
struct WIN32_FIND_DATAA
    {
    u32 dwFileAttributes;
    u32 ftc0;
    u32 ftc1;
    u32 fta0;
    u32 fta1;
    u32 ftw0;
    u32 ftw1; // three FILETIMEs
    u32 nFileSizeHigh;
    u32 nFileSizeLow;
    u32 dwReserved0;
    u32 dwReserved1;
    u8 cFileName[260];
    u8 cAlternateFileName[14];
    } pointer FindFirstFileA(pointer pattern, pointer wfd); // -> handle, or INVALID_HANDLE_VALUE
i32 FindNextFileA(pointer h, pointer wfd);
i32 FindClose(pointer h);
#define INVALID_HANDLE_VALUE $FFFFFFFFFFFFFFFF
#define FILE_ATTRIBUTE_DIRECTORY $0010
i32 DeleteFileA(pointer path);
i32 MoveFileA(pointer src, pointer dst);
i32 CopyFileA(pointer src, pointer dst, i32 failIfExists);
#define WS_CHILD $40000000
#define WS_VISIBLE $10000000
#define WS_TABSTOP $00010000
#define WS_GROUP $00020000
#define WS_BORDER $00800000
#define BS_PUSHBUTTON 0
#define BS_AUTOCHECKBOX 3
#define BS_AUTORADIOBUTTON 9
#define BS_GROUPBOX 7
#define ES_AUTOHSCROLL $0080
#define ES_PASSWORD $0020 // EDIT masks input with the password char (••••)
#define SS_LEFT 0
#define SS_CENTER 1
#define SS_RIGHT 2
#define ES_CENTER 1
#define ES_RIGHT 2
#define GWL_STYLE (-16)
#define WM_SETFONT $0030
#define WM_SETTEXT $000C
#define BM_SETCHECK $00F1
#define BM_GETCHECK $00F0
#define DEFAULT_GUI_FONT 17
#define EN_CHANGE $0300 // HIWORD(wParam) on WM_COMMAND from an EDIT
#define BN_CLICKED 0
#define EM_SETCUEBANNER $1501 // grey placeholder prompt on an EDIT (wParam=drawWhenFocused, lParam=LPCWSTR)

// ---- the native table: a SysListView32 (comctl32) --------------------------------------------
#import <comctl32> // links libcomctl32.a; InitCommonControlsEx registers the class
struct INITCOMMONCONTROLSEX
    {
    u32 dwSize;
    u32 dwICC;
    } i32 InitCommonControlsEx(pointer icc);
#define ICC_LISTVIEW_CLASSES $0001
#define ICC_TREEVIEW_CLASSES $0002
#define ICC_BAR_CLASSES $0004 // toolbar / statusbar / trackbar / tooltip
#define ICC_TAB_CLASSES $0008
#define ICC_UPDOWN_CLASS $0010
#define ICC_PROGRESS_CLASS $0020
// Trackbar (native slider): msctls_trackbar32
#define TBS_HORZ 0
#define TBS_AUTOTICKS $0001
#define TBM_GETPOS $0400
#define TBM_SETPOS $0405
#define TBM_SETRANGEMIN $0407
#define TBM_SETRANGEMAX $0408
// ComboBox (native popup): CBS_DROPDOWNLIST is a non-editable drop-down
#define CBS_DROPDOWNLIST $0003
#define CB_ADDSTRING $0143
#define CB_SETCURSEL $014E
#define CB_GETCURSEL $0147
#define CBN_SELCHANGE 1
// UpDown (native stepper): msctls_updown32 (standalone -> WM_VSCROLL)
#define UDS_ARROWKEYS $0020
#define UDS_NOTHOUSANDS $0080
#define UDM_SETRANGE $0465
#define UDM_SETPOS $0467
#define UDM_GETPOS $0468
#define UDM_SETRANGE32 $046F // wParam = low, lParam = high (clearer than the 16-bit UDM_SETRANGE)
#define UDM_SETPOS32 $0471   // lParam = position
#define UDM_GETPOS32 $0472
// Progress bar (native): msctls_progress32
#define PBM_SETRANGE32 $0406
#define PBM_SETPOS $0402
// Toolbar (native): ToolbarWindow32 — serves BOTH the UXToolbar (a row of text buttons) and the
// UXSegmentedControl (a check-group: connected buttons, Win32 enforces the radio/toggle exclusion).
// TBBUTTON is hand-padded to the Win64 C layout: after fsState/fsStyle come 6 reserved bytes so the
// pointer-sized dwData lands at offset 16 (get this wrong and TB_ADDBUTTONS reads garble).
struct TBBUTTON
    {
    i32 iBitmap;
    i32 idCommand;
    u8 fsState;
    u8 fsStyle;
    u8 r0;
    u8 r1;
    u8 r2;
    u8 r3;
    u8 r4;
    u8 r5;
    pointer dwData;
    pointer iString;
    }
#define TB_ADDBUTTONS $0414       // WM_USER+20 : wParam=count, lParam=TBBUTTON[]
#define TB_ADDSTRINGA $041C       // WM_USER+28 : lParam=double-NUL string list, returns first index
#define TB_CHECKBUTTON $0402      // WM_USER+2  : wParam=idCommand, lParam=LOWORD(fChecked)
#define TB_ISBUTTONCHECKED $040A  // WM_USER+10 : wParam=idCommand -> nonzero if checked
#define TB_BUTTONSTRUCTSIZE $041E // WM_USER+30 : MUST send once (=sizeof TBBUTTON) before ADDBUTTONS
#define TB_AUTOSIZE $0421         // WM_USER+33 : recompute button rects after ADDBUTTONS
#define TB_SETIMAGELIST $0430     // WM_USER+48 : wParam=index(0), lParam=HIMAGELIST -> the button icons
    // We build the image list BY HAND: Wine's TB_LOADIMAGES(HINST_COMMCTRL) yields an EMPTY list
    // (imagecount=0), so the standard system bitmaps are simply not there.  A hand-drawn list works on
    // both Wine and real Windows.  These are the GDI + comctl32 calls that build a 16x16 glyph bitmap.
    pointer GetDC(pointer hwnd);
i32 ReleaseDC(pointer hwnd, pointer hdc);
pointer CreateCompatibleDC(pointer hdc);
// Measure a string in the DC's current font: fills a SIZE {cx,cy}.  The toolkit needs this to break
// lines in the font it will actually draw with, outside any WM_PAINT.
i32 GetTextExtentPoint32A(pointer hdc, pointer s, i32 n, pointer size);
i32 DeleteDC(pointer hdc);
pointer CreateCompatibleBitmap(pointer hdc, i32 w, i32 h);
u32 GetPixel(pointer hdc, i32 x, i32 y); // read a pixel back (COLORREF 0x00BBGGRR) — offscreen tests
pointer ImageList_Create(i32 cx, i32 cy, u32 flags, i32 cInitial, i32 cGrow);
i32 ImageList_Add(pointer himl, pointer hbmImage, pointer hbmMask);
#define ILC_COLOR32 $0020
// Our own glyph indices (map a neutral toolbar item's ident to one of these; see w32StdImage).
#define TBI_NEW 0
#define TBI_OPEN 1
#define TBI_DELETE 2
#define TBI_GENERIC 3
#define TBSTATE_CHECKED $01
#define TBSTATE_ENABLED $04
#define TBSTYLE_LIST $1000 // text beside (not under) the (absent) icon — a horizontal button row
#define BTNS_BUTTON $00
#define BTNS_SEP $01
#define BTNS_CHECK $02
#define BTNS_GROUP $04
#define BTNS_CHECKGROUP $06 // CHECK|GROUP : the segmented control's radio-of-buttons
#define BTNS_AUTOSIZE $10   // size the button to its text
#define BTNS_SHOWTEXT $40   // draw iString beside the button (needs TBSTYLE_LIST)
// CCS_* keep the toolbar AT the frame we give it instead of snapping to the top of the parent.
#define CCS_NORESIZE $0004
#define CCS_NOPARENTALIGN $0008
#define CCS_NODIVIDER $0040
// LVCOLUMNA / LVITEMA — hand-padded to the win64 C layout (xtc packs, so the pointer-alignment gaps
// are explicit _pad fields; get these wrong and comctl32 reads the wrong offsets).
struct LVCOLUMN
    {
    u32 mask;
    i32 fmt;
    i32 cx;
    i32 _pad0;
    pointer pszText;
    i32 cchTextMax;
    i32 iSubItem;
    i32 iImage;
    i32 iOrder;
    } struct LVITEM
    {
    u32 mask;
    i32 iItem;
    i32 iSubItem;
    u32 state;
    u32 stateMask;
    i32 _pad0;
    pointer pszText;
    i32 cchTextMax;
    i32 iImage;
    pointer lParam;
    i32 iIndent;
    i32 _pad1;
    } struct NMHDR
    {
    pointer hwndFrom;
    pointer idFrom;
    u32 code;
    i32 _pad0;
    }

    // ---- SysTreeView32 (comctl32) : the native tree for UXOutlineView -----------------------------
    // TVITEM: mask, then hItem is 8-byte aligned (pad after the u32 mask), matching the Win64 C layout.
    struct TVITEM
    {
    u32 mask;
    i32 _pad0;
    pointer hItem;
    u32 state;
    u32 stateMask;
    pointer pszText;
    i32 cchTextMax;
    i32 iImage;
    i32 iSelectedImage;
    i32 cChildren;
    pointer lParam;
    }
    // TVINSERTSTRUCT: two handles then an inlined TVITEM (item member).
    struct TVINSERTSTRUCT
    {
    pointer hParent;
    pointer hInsertAfter;
    u32 mask;
    i32 _pad0;
    pointer hItem;
    u32 state;
    u32 stateMask;
    pointer pszText;
    i32 cchTextMax;
    i32 iImage;
    i32 iSelectedImage;
    i32 cChildren;
    pointer lParam;
    }
    // NMTREEVIEW: NMHDR (24) + action (+pad) + itemOld (TVITEM,56) + itemNew (TVITEM,56) + POINT (8).
    struct NMTREEVIEW
    {
    pointer hwndFrom;
    pointer idFrom;
    u32 code;
    u32 action; // hdr(24 incl this u32) + action
    u32 oMask;
    i32 _o0;
    pointer oHItem;
    u32 oState;
    u32 oStateMask; // itemOld
    pointer oPszText;
    i32 oCch;
    i32 oImg;
    i32 oSelImg;
    i32 oCh;
    pointer oLParam;
    u32 nMask;
    i32 _n0;
    pointer nHItem;
    u32 nState;
    u32 nStateMask; // itemNew
    pointer nPszText;
    i32 nCch;
    i32 nImg;
    i32 nSelImg;
    i32 nCh;
    pointer nLParam;
    i32 ptx;
    i32 pty;
    }
#define TVM_FIRST $1100
#define TVM_INSERTITEMA $1100 // TVM_FIRST + 0
#define TVM_DELETEITEM $1101  // TVM_FIRST + 1
#define TVM_EXPAND $1102      // TVM_FIRST + 2
#define TVM_GETNEXTITEM $110A // TVM_FIRST + 10
#define TVM_SELECTITEM $110B  // TVM_FIRST + 11
#define TVM_GETITEMA $110C    // TVM_FIRST + 12
#define TVS_HASBUTTONS $0001
#define TVS_HASLINES $0002
#define TVS_LINESATROOT $0004
#define TVS_SHOWSELALWAYS $0020
#define TVIF_TEXT $0001
#define TVIF_PARAM $0004
#define TVIF_HANDLE $0010
#define TVE_EXPAND $0002
#define TVGN_CARET $0009
#define TVACT_EXPAND $0002 // NMTREEVIEW.action for an expand (else a collapse)
// TVI_ROOT / TVI_LAST are pointer sentinels: (HTREEITEM)-0x10000 etc., SIGN-EXTENDED to 64 bits
// (0xFFFF0000 would be a bogus low address and the insert fails, dropping children to the real root).
#define TVI_ROOT $FFFFFFFFFFFF0000
#define TVI_LAST $FFFFFFFFFFFF0002
// TVN_ (WM_NOTIFY codes): TVN_FIRST = -400.  SELCHANGEDA = -402, ITEMEXPANDEDA = -406 (as u32).
#define TVN_SELCHANGEDA $FFFFFE6E
#define TVN_ITEMEXPANDEDA $FFFFFE6A
#define LVM_FIRST $1000
#define LVM_INSERTITEMA $1007
#define LVM_DELETEALLITEMS $1009
#define LVM_GETITEMCOUNT $1004
#define LVM_GETSELECTEDCOUNT $1032 // how many rows are selected (no index argument)
#define LVM_GETITEMSTATE $102C     // one row's state bits (index in wParam)   // rows the native list actually holds (a test can ask)
#define LVM_GETNEXTITEM $100C
#define LVM_INSERTCOLUMNA $101B
#define LVM_SETITEMSTATE $102B
#define LVM_SETITEMTEXTA $102E
#define LVM_SETEXTENDEDLISTVIEWSTYLE $1036
// Scrolling a report-mode list: LVM_SCROLL's dy is in LINES for LVS_REPORT (pixels in every other
// view), and LVM_GETTOPINDEX is the row currently at the top — together they are a seek, and
// LVM_GETITEMRECT on row 0 gives the row height that converts pixels to rows.
#define LVM_SCROLL $1014
#define LVM_GETTOPINDEX $1027
#define LVM_GETITEMRECT $100E
#define LVS_REPORT $0001
#define LVS_SINGLESEL $0004
#define LVS_SHOWSELALWAYS $0008
#define LVS_EX_GRIDLINES $0001
#define LVS_EX_FULLROWSELECT $0020
#define LVIF_TEXT $0001
#define LVIF_STATE $0008
#define LVCF_TEXT $0004
#define LVCF_WIDTH $0002
#define LVCF_SUBITEM $0008
#define LVIS_SELECTED $0002
#define LVNI_SELECTED $0002
#define WM_NOTIFY $004E
#define LVN_ITEMCHANGED $FFFFFF9B // LVN_FIRST(-100) - 1 = -101, as u32
#define TRANSPARENT 1
#define DKGRAY_BRUSH 3
#define NULL_PEN 8 // Polygon() outlines with the current pen unless this one is in
    // A GEOMETRIC pen is the one that has a width, joins and caps — a cosmetic pen is always 1px.  With
    // one selected, PolyBezierTo strokes the CURVE itself, which is what makes a wide stroke smooth
    // rather than an offset of a whole-pixel polyline.
    struct LOGBRUSH
    {
    u32 lbStyle;
    u32 lbColor;
    pointer lbHatch;
    } pointer ExtCreatePen(u32 penStyle, u32 width, pointer lb, u32 styleCount, pointer style);
i32 MoveToEx(pointer hdc, i32 x, i32 y, pointer oldPt);
i32 LineTo(pointer hdc, i32 x, i32 y);
i32 PolyBezierTo(pointer hdc, pointer pts, u32 n); // 3 points per cubic, from the current point
#define PS_GEOMETRIC $00010000
#define PS_SOLID $00000000
#define PS_ENDCAP_ROUND $00000000
#define PS_ENDCAP_SQUARE $00000100
#define PS_ENDCAP_FLAT $00000200
#define PS_JOIN_ROUND $00000000
#define BS_SOLID 0
// AppendMenu / Check / Enable flags
#define MF_STRING $0000
#define MF_POPUP $0010
#define MF_SEPARATOR $0800
#define MF_CHECKED $0008
#define MF_UNCHECKED $0000
#define MF_ENABLED $0000
#define MF_GRAYED $0001
#define MF_BYCOMMAND $0000
// MessageBox types, icons, and return ids
#define MB_OK $0000
#define MB_OKCANCEL $0001
#define MB_YESNOCANCEL $0003
#define MB_YESNO $0004
#define MB_ICONSTOP $0010
#define MB_ICONINFO $0040
#define IDOK 1
#define IDCANCEL 2
#define IDYES 6
#define IDNO 7
#define WH_CBT 5
#define HCBT_ACTIVATE 5
// Scrollbar
#define WS_VSCROLL $00200000
#define WS_HSCROLL $00100000
#define WM_VSCROLL $0115
#define WM_HSCROLL $0114
#define WM_MOUSEWHEEL $020A // wParam hi word = signed wheel delta (WHEEL_DELTA = 120/notch)
#define WM_SIZE $0005       // lParam lo/hi = new client width/height
#define CS_VREDRAW $0001    // repaint the whole window on any height change...
#define CS_HREDRAW $0002    // ...and on any width change (so a shrink redraws too)
#define SB_HORZ 0
#define SB_VERT 1
#define SB_LINEUP 0
#define SB_LINEDOWN 1
#define SB_PAGEUP 2
#define SB_PAGEDOWN 3
#define SB_THUMBPOSITION 4
#define SB_THUMBTRACK 5
#define SB_ENDSCROLL 8 // the "drag released" notification — same position as the last, so ignore it
