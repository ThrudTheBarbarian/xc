// UXWin32Driver.xc — the Win32 realization of UXViewDriver.  The sibling of UXGemDriver: it
// implements the SAME neutral interface, so the neutral toolkit (UXView/UXWindow/UXViewTree/
// the widgets) runs on Win32 unchanged.
//
// Where GEM had the AES's OBJECT[] and objc_draw/objc_find, this driver keeps its own SHADOW
// TREE (a flat node array with parent/sibling links) and walks it itself — for painting
// (WM_PAINT -> the neutral draw seam via the registered callbacks) and hit-testing.  HWNDs are
// pointer-width, so they live in a small table indexed by the i32 handle the protocol uses.
//
// Menus, field editors, scrolling, tables/outlines, the toolbar and the common dialogs are all
// live here now; what is NOT is listed against the protocol methods that return a constant —
// notably windowSetSubtitle/Info/Icon/Modified, which Win32 has no window-chrome equivalent for.
#import <Stdio.xc>
#import "UXViewDriver.xc"
#import "UXControl.xc"          // UXCheckbox / UXRadioButton — the driver reads their toggle state
#import "UXTableView.xc"        // the native SysListView32 reads columns/rows from the peer UXTableView
#import "UXOutlineView.xc"      // the native SysTreeView32 reads the item tree from the peer UXOutlineView
#import "UXSlider.xc"           // native trackbar (msctls_trackbar32)
#import "UXPopUpButton.xc"      // native combobox (CBS_DROPDOWNLIST)
#import "UXStepper.xc"          // native up-down (msctls_updown32)
#import "UXProgressBar.xc"      // native progress bar (msctls_progress32)
#import "UXSegmentedControl.xc" // native ToolbarWindow32 check-group (connected buttons, one/many selected)
#import "UXToolbar.xc"          // native ToolbarWindow32 button row
#import "UXTextView.xc"         // native RichEdit
#import "Array.xc"
#import "UXWin32.h.xc"
#import "UXDate.xc" // localOffsetMinutes compares civil days
#import "UXGdiGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"
#import "UXLibc.xc"

// The draw-seam callbacks, as callable function-pointer types (xtc can call these directly).
typedef void UXContentFn(i32 handle, i32 wx, i32 wy, i32 ww, i32 wh, pointer ud);
typedef i32 UXUserDrawFn(pointer tree, i32 obj, pointer ud);

// ── the shadow tree ─────────────────────────────────────────────────────────
// One node per view.  next = next sibling (-1 = last); head/tail = child span; parent for
// absolute-frame walks.  The neutral layer only ever names the INDEX.
struct W32Node
    {
    i32 kind;
    i16 x;
    i16 y;
    i16 w;
    i16 h;
    i16 hidden;
    i16 selected;
    i16 enabled;
    i16 clips;
    i16 clipR;     // a clipping node's corner radius (structSetClipShape)
    i16 clipIn;    // ...and the inset of its clip from its frame
    i16 selectable;
    i16 editable;
    pointer spec;
    i16 next;
    i16 head;
    i16 tail;
    i16 parent;
    pointer ctrl; // the native child HWND realizeTree created for this node (0 = none / custom-drawn)
    pointer peer; // the neutral widget (UXCheckbox/UXRadioButton), for reading toggle state
    } struct W32Tree
    {
    W32Node* nodes;
    i32 count;
    i32 cap;
    }

    // A field editor: the app's buffer, its capacity, and an optional per-position validation
    // string (see UXTextField.setValidation).  On GEM this is a TEDINFO the AES's objc_edit drives;
    // Win32 has no edit engine for a custom view, so the driver does the editing — insert, Backspace,
    // caret, and per-character validation — against this.
    // field=neutral UXTextField; place=cue banner
    struct W32Field
    {
    u8* buf;
    i32 cap;
    u8* valid;
    pointer field;
    u8* place;
    i32 secure;
    }

    // ── driver state ────────────────────────────────────────────────────────────
    i32 gW32Native;     // §10 native-object counter (live windows)
pointer gW32Hwnds[64];  // i32 handle -> HWND (handles start at 1)
// Tests only: a hook for the common dialogs (ChooseColor, ChooseFont, GetOpenFileName,
// GetSaveFileName).  It sees the real dialog's messages first, so a gate can answer the dialog as a
// user would; 0 in an app.
pointer gW32TestDialogHook;
// The parts a Windows title is composed of (UXKit's title, subtitle and modified flag), by handle.
u8* gW32Title[64];
u8* gW32Subtitle[64];
bool gW32Modified[64];
i32 gW32WinH[64];       // handle -> window client height (for the scroll range)
i32 gW32WinW[64];       // handle -> window client width
i32 gW32ScrollY[64];    // handle -> current vertical scroll offset
i32 gW32ScrollX[64];    // handle -> current horizontal scroll offset
i32 gW32ScrollMax[64];  // handle -> max vertical scroll offset (content - visible)
i32 gW32ScrollMaxX[64]; // handle -> max horizontal scroll offset
i32 gW32NextHandle;
pointer gW32Inst;       // HINSTANCE
UXGdiGraphics* gW32Gfx; // the one context, bound per paint
pointer gW32ContentFn;  // the window content callback (ux_window_draw)
pointer gW32UserFn;     // the per-view draw callback (ux_userdraw)
pointer gW32UserUd;
pointer gW32CurHdc; // the DC of the paint in flight
i32 gW32DrawOX;     // draw-origin offset for a scroll child's subtree paint (else 0)
i32 gW32DrawOY;
W32Tree* gW32DrawTree;   // the tree being painted (so the recursion can reach nodes)
pointer gW32Menu;        // the app menu bar (an HMENU), attached to every window
pointer gW32Font;        // the system UI font (DEFAULT_GUI_FONT), set on every native control
pointer gW32FaceBrush;   // the dialog-face grey: window background + control-label backdrop
pointer gW32TbImages;    // the hand-drawn toolbar image list (built once, shared by all toolbars)
UXEvent* gW32ClickEvent; // reused synthetic event handed to a control's mouseDown
pointer gW32MeasureDC;   // a screen-compatible DC kept for text measurement (textWidth)
// Set while the driver is WRITING a selection into a native list.  Every LVM_SETITEMSTATE fires
// LVN_ITEMCHANGED straight back — "the user changed the selection" — and letting that reach
// applyNativeSelection mid-push means the model is overwritten with a half-finished state, one row
// at a time, and ends up agreeing with nothing.
i32 gW32SelPush;

// ── the settings file ───────────────────────────────────────────────────────
// %APPDATA%\UXKit\UXKit.ini, resolved once.  A free function rather than a method because it is pure
// path arithmetic, and globals rather than locals because the answer outlives the call.
u8 gW32SetPath[320];
// The sentinel default handed to GetPrivateProfileStringA, so that "the key holds an empty string"
// and "there is no key" can be told apart.  Built from BYTES rather than written "\x01": xtc does
// not interpret hex escapes in a literal, and a sentinel that is really four printable characters
// silently makes every missing key look present.
u8 gW32NoValue[2];

i32 w32PutStr(u8* dst, i32 at, u8* s)
    {
    i32 i = (i32)0;
    while (s[i] != (u8)0)
        {
        dst[at + i] = s[i];
        i = i + (i32)1;
        }
    dst[at + i] = (u8)0;
    return at + i;
    }
u8* w32SettingsFile(void)
    {
    if (gW32SetPath[(i32)0] != (u8)0)
        {
        return &gW32SetPath[(i32)0];
        }
    u32 n = GetEnvironmentVariableA((pointer) "APPDATA", (pointer)&gW32SetPath[(i32)0], (u32)256);
    i32 at = (i32)n;
    if (n == (u32)0 || n > (u32)255)
        {
        at = w32PutStr(&gW32SetPath[(i32)0], (i32)0, (u8*)".");
        }
    at = w32PutStr(&gW32SetPath[(i32)0], at, (u8*)"\\UXKit");
    CreateDirectoryA((pointer)&gW32SetPath[(i32)0], (pointer)0); // first run: no directory yet
    w32PutStr(&gW32SetPath[(i32)0], at, (u8*)"\\UXKit.ini");
    return &gW32SetPath[(i32)0];
    }
u8* w32NoValue(void)
    {
    gW32NoValue[(i32)0] = (u8)1;
    gW32NoValue[(i32)1] = (u8)0;
    return &gW32NoValue[(i32)0];
    }

// HWND -> our window handle, as a free function: the window PROC needs it too, and it is not a method.
i32 w32HandleOf(pointer hwnd)
    {
    for (i32 i = (i32)1; i < gW32NextHandle; i = i + (i32)1)
        {
        if (gW32Hwnds[i] == hwnd)
            {
            return i;
            }
        }
    return (i32)0;
    }

// ---- drags, drops, context menus and the drag line ---------------------------------------------
pointer gW32TreeOf[64];        // handle -> the shadow tree realizeTree last saw, for hit tests
i32 gW32MinW[64];              // handle -> the smallest content size (setMinimumSize), 0 = none
i32 gW32MinH[64];
pointer gW32LineWin[64];       // handle -> its line window (a click-through layer over the content)
i32 gW32LineV[512];            // handle * 8: x0 y0 x1 y1, then the framed rect
i32 gW32LineClass;
i32 gW32LineOn[64];            // handle -> whether its line is up
i32 gW32MenuTestPick = (i32)-2; // a test's answer for the next pop-up menu (-2: show it)
u8 gW32MenuTestTitles[512];

// The app's window a child window is in: its handle, and its HWND into top.
i32 w32TopHandle(pointer hwnd, pointer* top)
    {
    pointer h = hwnd;
    while (h != (pointer)0)
        {
        i32 k = w32HandleOf(h);
        if (k != (i32)0)
            {
            top[0] = h;
            return k;
            }
        h = GetParent(h);
        }
    return (i32)0;
    }
// A row dragged out of a list or a tree, from (sx, sy) in src's client coords: the mouse is held
// until the button comes up, every move is reported to the app as a hover in the window's content
// coords, and the release as a drop there.  A tree's drag first reports where it began, so a line
// can start at the row, and the tree row under the pointer is highlighted as a drop target.
void w32RowDrag(pointer src, bool isTree, u8* text, bool right, i32 sx, i32 sy)
    {
    pointer top = (pointer)0;
    i32 handle = w32TopHandle(src, &top);
    if (handle == (i32)0 || gApp == (UXApplication*)0 || text == (u8*)0)
        {
        return;
        }
    POINT p;
    p.x = sx;
    p.y = sy;
    ClientToScreen(src, (pointer)&p);
    ScreenToClient(top, (pointer)&p);
    if (isTree)
        {
        gApp.deliverItemHover(text, handle, p.x, p.y);
        }
    SetCapture(top);
    MSG m;
    bool drop = false;
    pointer lit = (pointer)0;
    i32 ex = (i32)0;
    i32 ey = (i32)0;
    while (GetMessageA((pointer)&m, (pointer)0, (u32)0, (u32)0) > (i32)0)
        {
        if (m.message == (u32)WM_MOUSEMOVE)
            {
            // captured, the move's point is in top's client coords (signed 16-bit halves)
            POINT q;
            q.x = (i32)(i16)((u32)m.lParam & (u32)$FFFF);
            q.y = (i32)(i16)(((u32)m.lParam >> (u32)16) & (u32)$FFFF);
            if (isTree)
                {
                POINT tq;
                tq.x = q.x;
                tq.y = q.y;
                ClientToScreen(top, (pointer)&tq);
                ScreenToClient(src, (pointer)&tq);
                TVHITTESTINFO hi;
                hi.ptx = tq.x;
                hi.pty = tq.y;
                hi.flags = (u32)0;
                hi.hItem = (pointer)0;
                pointer it = SendMessageA(src, (u32)TVM_HITTEST, (pointer)0, (pointer)&hi);
                if (it != lit)
                    {
                    SendMessageA(src, (u32)TVM_SELECTITEM, (pointer)TVGN_DROPHILITE, it);
                    lit = it;
                    }
                }
            gApp.deliverItemHover(text, handle, q.x, q.y);
            continue;
            }
        if (m.message == (right ? (u32)WM_RBUTTONUP : (u32)WM_LBUTTONUP))
            {
            ex = (i32)(i16)((u32)m.lParam & (u32)$FFFF);
            ey = (i32)(i16)(((u32)m.lParam >> (u32)16) & (u32)$FFFF);
            drop = true;
            break;
            }
        if (m.message == (u32)WM_KEYDOWN && (u32)m.wParam == (u32)VK_ESCAPE)
            {
            break;
            }
        TranslateMessage((pointer)&m);
        DispatchMessageA((pointer)&m);
        }
    ReleaseCapture();
    if (isTree)
        {
        SendMessageA(src, (u32)TVM_SELECTITEM, (pointer)TVGN_DROPHILITE, (pointer)0);
        }
    gApp.deliverItemHover(text, handle, (i32)-1, (i32)-1);
    if (drop)
        {
        gApp.deliverItemDrop(text, handle, ex, ey);
        }
    }
// Whether two C strings are the same.
bool w32Same(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        {
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
// A native control's text, made `s` if it says something else: a title changed after it was made.
void w32SyncText(pointer c, u8* s)
    {
    if (c == (pointer)0 || s == (u8*)0)
        {
        return;
        }
    u8 buf[256];
    GetWindowTextA(c, (pointer)&buf[0], (i32)256);
    if (!w32Same(&buf[0], s))
        {
        SetWindowTextA(c, (pointer)s);
        }
    }
// The line window's paint: the colour key everywhere (so the layer is clear), then the S-curve, a
// frame round the target and a dot at the pointer.
pointer UXLine32Proc(pointer hwnd, u32 msg, pointer wp, pointer lp)
    {
    if (msg == (u32)WM_PAINT)
        {
        i32 h = (i32)GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA);
        PAINTSTRUCT ps;
        pointer dc = BeginPaint(hwnd, (pointer)&ps);
        RECT rc;
        GetClientRect(hwnd, (pointer)&rc);
        pointer key = CreateSolidBrush((u32)$00FF00FF);
        FillRect(dc, (pointer)&rc, key);
        DeleteObject(key);
        i32* L = &gW32LineV[h * (i32)8];
        pointer pen = CreatePen((i32)PS_SOLID, (i32)2, (u32)$00F27326); // RGB(38, 115, 242), as BGR
        pointer oldPen = SelectObject(dc, pen);
        pointer oldBrush = SelectObject(dc, GetStockObject((i32)NULL_BRUSH));
        if (L[6] > (i32)0 && L[7] > (i32)0)
            {
            Rectangle(dc, L[4] - (i32)1, L[5] - (i32)1, L[4] + L[6] + (i32)1, L[5] + L[7] + (i32)1);
            }
        i32 dx = L[2] - L[0];
        i32 ad = dx < (i32)0 ? (i32)0 - dx : dx;
        i32 k = ad / (i32)2 > (i32)30 ? ad / (i32)2 : (i32)30;
        i32 dir = dx < (i32)0 ? (i32)-1 : (i32)1;
        POINT pts[3];
        pts[0].x = L[0] + dir * k;
        pts[0].y = L[1];
        pts[1].x = L[2] - dir * k;
        pts[1].y = L[3];
        pts[2].x = L[2];
        pts[2].y = L[3];
        MoveToEx(dc, L[0], L[1], (pointer)0);
        PolyBezierTo(dc, (pointer)&pts[0], (u32)3);
        SelectObject(dc, oldBrush);
        pointer dotBrush = CreateSolidBrush((u32)$00F27326);
        pointer prevBrush = SelectObject(dc, dotBrush);
        Ellipse(dc, L[2] - (i32)3, L[3] - (i32)3, L[2] + (i32)4, L[3] + (i32)4);
        SelectObject(dc, prevBrush);
        DeleteObject(dotBrush);
        SelectObject(dc, oldPen);
        DeleteObject(pen);
        EndPaint(hwnd, (pointer)&ps);
        return (pointer)0;
        }
    return DefWindowProcA(hwnd, msg, wp, lp);
    }
// For tests: whether window `handle`'s line is up, and its far end.
i32 w32TestLine(i32 handle, i32* x1, i32* y1)
    {
    pointer lw = handle > (i32)0 && handle < (i32)64 ? gW32LineWin[handle] : (pointer)0;
    if (lw == (pointer)0 || gW32LineOn[handle] == (i32)0)
        {
        return (i32)0;
        }
    x1[0] = gW32LineV[handle * (i32)8 + (i32)2];
    y1[0] = gW32LineV[handle * (i32)8 + (i32)3];
    return (i32)1;
    }

// The live UXScroll32 containers, and the window each belongs to.  A scroll child is a SEPARATE
// HWND that paints its own slice of the tree, so invalidating the window's client area does not
// touch it — an app-driven change inside a scroll view (a row appended, a selection set from code)
// would sit unpainted until something else happened to expose the child.  windowInvalidate* walks
// this table so the neutral "this window needs a repaint" reaches the containers too.
#define W32_MAX_SCROLLERS 64
pointer gW32Scrollers[W32_MAX_SCROLLERS];
i32 gW32ScrollerWin[W32_MAX_SCROLLERS]; // owning window handle
i32 gW32ScrollerN;

// Remember a freshly created container (no-op past the table's capacity — the app just loses the
// programmatic repaint for that one, rather than corrupting the table).
void w32ScrollerAdd(pointer hwnd, i32 winHandle)
    {
    if (gW32ScrollerN >= (i32)W32_MAX_SCROLLERS)
        {
        return;
        }
    gW32Scrollers[gW32ScrollerN] = hwnd;
    gW32ScrollerWin[gW32ScrollerN] = winHandle;
    gW32ScrollerN = gW32ScrollerN + (i32)1;
    }
// Forget a closed window's containers: DestroyWindow took the children with it, so leaving them
// here would hand InvalidateRect a dangling HWND (and one Windows may have recycled).
void w32ScrollerDropWindow(i32 winHandle)
    {
    i32 w = (i32)0;
    for (i32 i = (i32)0; i < gW32ScrollerN; i = i + (i32)1)
        {
        if (gW32ScrollerWin[i] != winHandle)
            {
            gW32Scrollers[w] = gW32Scrollers[i];
            gW32ScrollerWin[w] = gW32ScrollerWin[i];
            w = w + (i32)1;
            }
        }
    gW32ScrollerN = w;
    }
// Repaint every container of one window.  The whole child, not a rect, and every container rather
// than the ones the damage rect crosses: the damage is in the tree's UNSCROLLED absolute space, so
// a change to a row scrolled out of reach reports a rect that misses the container's frame entirely
// — the one case that most needs the repaint.  Containers are few and small, so this is cheap.
// erase = FALSE: UXScroll32Proc's WM_PAINT fills the exposed area itself, and letting the class
// brush clear it first only adds a flash.
void w32ScrollersInvalidate(i32 winHandle)
    {
    for (i32 i = (i32)0; i < gW32ScrollerN; i = i + (i32)1)
        {
        if (gW32ScrollerWin[i] == winHandle)
            {
            InvalidateRect(gW32Scrollers[i], (pointer)0, (i32)0);
            }
        }
    }

// A native value control (trackbar/updown/combo) reported a new number: adopt it into the peer widget
// by type, then fire the widget's action.  The run loop's gNeedsDisplay check redisplays (which
// re-realizes, so e.g. a progress bar driven by a slider updates).  Win32 twin of xgAKValueChanged.
void w32ValueChanged(pointer ctrl, i32 value)
    {
    UXControl* c = (UXControl* ?)(Object*)GetWindowLongPtrA(ctrl, (i32)GWLP_USERDATA);
    if (c == (UXControl*)0)
        {
        return;
        }
    UXSlider* sl = (UXSlider* ?)c;
    if (sl != (UXSlider*)0)
        {
        sl.applyNativeValue(value);
        }
    UXStepper* st = (UXStepper* ?)c;
    if (st != (UXStepper*)0)
        {
        st.applyNativeValue(value);
        }
    UXPopUpButton* pu = (UXPopUpButton* ?)c;
    if (pu != (UXPopUpButton*)0)
        {
        pu.applyNativeSelection(value);
        }
    c.fire();
    }
#define W32_CTRL_ID_BASE 1000 // control ids start here so they never collide with menu-item ids

// Draw a UTF-8 string through the WIDE text API.  The neutral toolkit hands us UTF-8 (u8*); TextOutA
// would read those bytes as the ANSI code page and mangle any multibyte char (e.g. an em dash shows
// as "â€""), so convert to UTF-16 and use TextOutW.  A stack buffer avoids a per-glyph malloc; strings
// longer than it (MultiByteToWideChar returns 0 = won't fit) are simply skipped, which no label hits.
void w32DrawText(pointer hdc, i32 x, i32 y, u8* s)
    {
    u16 wbuf[512];
    i32 wch = MultiByteToWideChar((u32)CP_UTF8, (u32)0, (pointer)s, (i32)-1, (pointer)&wbuf[0], (i32)512);
    // wch counts the NUL
    if (wch > (i32)1)
        {
        TextOutW(hdc, x, y, (pointer)&wbuf[0], wch - (i32)1);
        }
    }

// Zero a TVITEM so only the masked fields carry meaning (comctl reads the whole struct).
void w32TvitemInit(TVITEM* it)
    {
    it.mask = (u32)0;
    it._pad0 = (i32)0;
    it.hItem = (pointer)0;
    it.state = (u32)0;
    it.stateMask = (u32)0;
    it.pszText = (pointer)0;
    it.cchTextMax = (i32)0;
    it.iImage = (i32)0;
    it.iSelectedImage = (i32)0;
    it.cChildren = (i32)0;
    it.lParam = (pointer)0;
    }

// Set a scroll child's vertical range from the content height + its client height (SetScrollPos then
// re-clamps the position).  0 range = the content fits, no thumb.
void w32ScrollRange(pointer hwnd, i32 contentH, i32 winH)
    {
    RECT rc;
    GetClientRect(hwnd, (pointer)&rc);
    i32 clientH = rc.bottom - rc.top;
    if (clientH <= (i32)0)
        {
        clientH = winH;
        }
    i32 mx = contentH - clientH;
    if (mx < (i32)0)
        {
        mx = (i32)0;
        }
    SetScrollRange(hwnd, (i32)SB_VERT, (i32)0, mx, (i32)1);
    SetScrollPos(hwnd, (i32)SB_VERT, GetScrollPos(hwnd, (i32)SB_VERT), (i32)1); // re-clamp
    }

// A rounded panel's edge: the rounded region framed 1px in the panel's border colour (the system's
// window-frame colour when only the radius is set, so the WS_BORDER it replaces keeps its look).  The
// edge crosses the client area at the corners and the scrollbar along the right, so it is framed after
// both paint: over the window DC from WM_NCPAINT, over the client from WM_PAINT (whose origin is the
// window's (1,1), hence the -1 offset).  Nothing for a square, unbordered panel.
void w32ScrollFrame(pointer hwnd, pointer hdc, i32 off)
    {
    UXScrollView* sv = (UXScrollView* ?)(Object*)GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA);
    if (sv == (UXScrollView*)0)
        {
        return;
        }
    i32 r = sv.nativeCornerRadius();
    i32 rgb = sv.nativeBorderRGB();
    if (r <= (i32)0 && rgb < (i32)0)
        {
        return;
        }
    UXRect f = sv.frame();
    u32 col = rgb >= (i32)0
            ? ((u32)(rgb & (i32)255) << (u32)16) | ((u32)((rgb >> (i32)8) & (i32)255) << (u32)8) | (u32)((rgb >> (i32)16) & (i32)255)
            : GetSysColor((i32)COLOR_WINDOWFRAME);
    pointer rgn = CreateRoundRectRgn(-off, -off, (i32)f.w + (i32)1 - off, (i32)f.h + (i32)1 - off, r * (i32)2, r * (i32)2);
    pointer br = CreateSolidBrush(col);
    FrameRgn(hdc, rgn, br, (i32)1, (i32)1);
    DeleteObject(br);
    DeleteObject(rgn);
    }
// After the bar moves: SetScrollPos repaints the bar straight over the edge, so frame it again.
void w32ScrollReframe(pointer hwnd)
    {
    pointer wdc = GetWindowDC(hwnd);
    w32ScrollFrame(hwnd, wdc, (i32)0);
    ReleaseDC(hwnd, wdc);
    }

// The scroll-child window proc: WS_VSCROLL owns the bar; WM_PAINT draws the peer UXScrollView's
// DOCUMENT subtree offset by the scroll position, into this child's client (its own 0,0).
// The scroller's client, painted into hdc: the document subtree at the scroll offset, then its frame.
// WM_PAINT and WM_PRINTCLIENT (a snapshot printing the window's children) both come here.
void w32ScrollPaint(pointer hwnd, pointer hdc)
    {
    SelectObject(hdc, gW32Font);
    RECT rc;
    GetClientRect(hwnd, (pointer)&rc);
    FillRect(hdc, (pointer)&rc, gW32FaceBrush); // clear the exposed area
    UXScrollView* sv = (UXScrollView* ?)(Object*)GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA);
    if (sv != (UXScrollView*)0)
        {
        i32 pos = GetScrollPos(hwnd, (i32)SB_VERT);
        UXRect svAbs = sv.absoluteFrame(); // the child's position in the parent window
        pointer was = gW32CurHdc;
        gW32CurHdc = hdc;
        // abs -> child-client, scrolled: a view at (vx,vy) draws at (vx-svAbs.x, vy-svAbs.y-pos).
        gDriver.setDrawOffset((i32)svAbs.x, (i32)svAbs.y + pos);
        gDriver.treeSetUserDraw((pointer)&ux_surface_userdraw, (pointer)sv.owner);
        gDriver.treeDraw((pointer)sv.owner.objects(), sv.nativeDocNode(),
                         (i32)0, (i32)0, (i32)(rc.right - rc.left), (i32)(rc.bottom - rc.top));
        gDriver.setDrawOffset((i32)0, (i32)0);
        gW32CurHdc = was;
        }
    w32ScrollFrame(hwnd, hdc, (i32)1);
    }

// The scroll-child window proc: WS_VSCROLL owns the bar; WM_PAINT draws the peer UXScrollView's
// DOCUMENT subtree offset by the scroll position, into this child's client (its own 0,0).
pointer UXScroll32Proc(pointer hwnd, u32 msg, pointer wp, pointer lp)
    {
    if (msg == (u32)WM_PAINT)
        {
        PAINTSTRUCT ps;
        pointer hdc = BeginPaint(hwnd, (pointer)&ps);
        w32ScrollPaint(hwnd, hdc);
        EndPaint(hwnd, (pointer)&ps);
        return (pointer)0;
        }
    if (msg == (u32)$0318) // WM_PRINTCLIENT
        {
        w32ScrollPaint(hwnd, wp);
        return (pointer)0;
        }
    if (msg == (u32)WM_NCPAINT)
        {
        pointer res = DefWindowProcA(hwnd, msg, wp, lp); // the bar and the square border
        w32ScrollReframe(hwnd);
        return res;
        }
    if (msg == (u32)WM_VSCROLL)
        {
        i32 code = (i32)((u32)wp & (u32)$FFFF);
        i32 pos = GetScrollPos(hwnd, (i32)SB_VERT);
        if (code == (i32)SB_LINEUP)
            {
            pos = pos - (i32)20;
            }
        else if (code == (i32)SB_LINEDOWN)
            {
            pos = pos + (i32)20;
            }
        else if (code == (i32)SB_PAGEUP)
            {
            pos = pos - (i32)100;
            }
        else if (code == (i32)SB_PAGEDOWN)
            {
            pos = pos + (i32)100;
            }
        else if (code == (i32)SB_THUMBPOSITION || code == (i32)SB_THUMBTRACK)
            {
            pos = (i32)(((u32)wp >> (u32)16) & (u32)$FFFF);
            }
        SetScrollPos(hwnd, (i32)SB_VERT, pos, (i32)1); // clamps to the range
        w32ScrollReframe(hwnd);
        InvalidateRect(hwnd, (pointer)0, (i32)1);
        return (pointer)0;
        }
    // A click lands on THIS child, not the canvas, so nextEvent never sees it and the subtree the
    // container paints (a self-drawn list) could not be clicked.  Map it to the parent's client, as it
    // shows on screen, and post it to the parent, where the toolkit's dispatchMouse hit-tests it like
    // any other click; the toolkit adds the scroll position itself (UXWindow.hitScrolled), so a real
    // click and a synthetic one agree.
    // Posted input outranks WM_PAINT, so invalidating now repaints AFTER the click has been handled.
    if (msg == (u32)WM_LBUTTONDOWN)
        {
        UXScrollView* sv = (UXScrollView* ?)(Object*)GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA);
        pointer par = GetParent(hwnd);
        if (sv != (UXScrollView*)0 && par != (pointer)0)
            {
            u32 lpw = (u32)lp;
            UXRect svAbs = sv.absoluteFrame();
            i32 x = (i32)(i16)lpw + (i32)svAbs.x;
            i32 y = (i32)(i16)(lpw >> (u32)16) + (i32)svAbs.y;
            PostMessageA(par, (u32)WM_LBUTTONDOWN, wp,
                         (pointer)(((u32)y << (u32)16) | ((u32)x & (u32)$FFFF)));
            InvalidateRect(hwnd, (pointer)0, (i32)1);
            }
        return (pointer)0;
        }
    if (msg == (u32)WM_MOUSEWHEEL)
        {
        i32 delta = (i32)(((u32)wp >> (u32)16) & (u32)$FFFF);
        if (delta >= (i32)32768)
            {
            delta = delta - (i32)65536;
            }
        i32 pos = GetScrollPos(hwnd, (i32)SB_VERT) - (delta / (i32)120) * (i32)40;
        SetScrollPos(hwnd, (i32)SB_VERT, pos, (i32)1);
        w32ScrollReframe(hwnd);
        InvalidateRect(hwnd, (pointer)0, (i32)1);
        return (pointer)0;
        }
    return DefWindowProcA(hwnd, msg, wp, lp);
    }

// ── the window proc: the driver ─────────────────────────────────────────────
// WM_PAINT flows backend -> the neutral content callback -> treeDraw -> drawRect.
// ---- the native text view (UXTextView): a RichEdit -------------------------------------------------
// The RichEdit holds UTF-16 with a CR at each paragraph's end; the toolkit's side is UTF-8 with LF, so
// text is converted here, one CR for one LF (the offsets stay in step).  A style is set over a range by
// selecting it; reading the runs back asks for the format of growing ranges, which the RichEdit reports
// as mixed (a bit cleared in the mask) once a range covers two.  The RichEdit's own undo is off, because
// the view keeps one that covers its styles as well (as on GTK and the web).
Array* gW32TextViews;
pointer gW32RichLib;
class W32TextView : Object
    {
    pointer hwnd;
    UXTextView* tv;
    i32 handle;
    i32 node;
    i32 quiet;      // a change the toolkit is making is not reported back to it
    bool userMoved; // the next selection change is the user's (a click, a drag, a moving key)
    i32 defHeight;  // the default font's height, in twips
    u16 defFace[32];

    static W32TextView* of(pointer h)
        {
        if (gW32TextViews == (Array*)0 || h == (pointer)0)
            {
            return (W32TextView*)0;
            }
        for (u32 k = (u32)0; k < gW32TextViews.count(); k = k + (u32)1)
            {
            W32TextView* r = (W32TextView* ?)gW32TextViews.get(k);
            if (r != (W32TextView*)0 && r.hwnd == h)
                {
                return r;
                }
            }
        return (W32TextView*)0;
        }
    static W32TextView* at(i32 handle, i32 node)
        {
        if (gW32TextViews == (Array*)0)
            {
            return (W32TextView*)0;
            }
        for (u32 k = (u32)0; k < gW32TextViews.count(); k = k + (u32)1)
            {
            W32TextView* r = (W32TextView* ?)gW32TextViews.get(k);
            if (r != (W32TextView*)0 && r.handle == handle && r.node == node)
                {
                return r;
                }
            }
        return (W32TextView*)0;
        }
    static W32TextView* make(i32 handle, i32 node, pointer parent, i32 x, i32 y, i32 w, i32 h, UXTextView* tv)
        {
        if (gW32RichLib == (pointer)0)
            {
            gW32RichLib = LoadLibraryA((pointer)"Msftedit.dll");
            }
        u32 st = (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)WS_VSCROLL | (u32)WS_TABSTOP | (u32)ES_MULTILINE |
                 (u32)ES_AUTOVSCROLL | (u32)ES_WANTRETURN;
        pointer c = CreateWindowExA((u32)WS_EX_CLIENTEDGE, (pointer) "RICHEDIT50W", (pointer) "", st, x, y, w, h, parent,
                                    (pointer)(W32_CTRL_ID_BASE + node), gW32Inst, (pointer)0);
        if (c == (pointer)0)
            {
            return (W32TextView*)0;
            }
        W32TextView* r = new W32TextView();
        r.hwnd = c;
        r.tv = tv;
        r.handle = handle;
        r.node = node;
        r.quiet = (i32)0;
        r.userMoved = false;
        SendMessageA(c, (u32)WM_SETFONT, gW32Font, (pointer)1);
        SendMessageA(c, (u32)EM_SETUNDOLIMIT, (pointer)0, (pointer)0);
        SendMessageA(c, (u32)EM_SETEVENTMASK, (pointer)0, (pointer)((u32)ENM_CHANGE | (u32)ENM_SELCHANGE));
        u8 cf[116];
        r.zero(&cf[0], (i32)116);
        ((u32*)&cf[0])[0] = (u32)116;
        SendMessageA(c, (u32)EM_GETCHARFORMAT, (pointer)SCF_DEFAULT, (pointer)&cf[0]);
        r.defHeight = ((i32*)&cf[12])[0];
        u16* face = (u16*)&cf[26];
        for (i32 k = (i32)0; k < (i32)32; k = k + (i32)1)
            {
            r.defFace[k] = face[k];
            }
        if (gW32TextViews == (Array*)0)
            {
            gW32TextViews = new Array();
            }
        gW32TextViews.add(r);
        return r;
        }

    void zero(u8* p, i32 n)
        {
        for (i32 k = (i32)0; k < n; k = k + (i32)1)
            {
            p[k] = (u8)0;
            }
        }

    // ---- the text: UTF-16 with CRs, the caller frees it ----
    u16* wide(i32* n)
        {
        u8 gl[8];
        ((u32*)&gl[0])[0] = (u32)10; // GTL_NUMCHARS | GTL_PRECISE
        ((u32*)&gl[0])[1] = (u32)CP_UTF16;
        i32 len = (i32)SendMessageA(hwnd, (u32)EM_GETTEXTLENGTHEX, (pointer)&gl[0], (pointer)0);
        if (len < (i32)0)
            {
            len = (i32)0;
            }
        u16* buf = (u16*)malloc((u32)(len + (i32)1) * (u32)2);
        u8 gt[32];
        self.zero(&gt[0], (i32)32);
        ((u32*)&gt[0])[0] = (u32)(len + (i32)1) * (u32)2;
        ((u32*)&gt[0])[2] = (u32)CP_UTF16;
        i32 got = (i32)SendMessageA(hwnd, (u32)EM_GETTEXTEX, (pointer)&gt[0], (pointer)buf);
        if (got < (i32)0 || got > len)
            {
            got = (i32)0;
            }
        buf[got] = (u16)0;
        n[0] = got;
        return buf;
        }
    // UTF-16 (CR) to UTF-8 (LF); the caller frees it
    static u8* utf8Of(u16* w, i32 n, i32* nb)
        {
        for (i32 k = (i32)0; k < n; k = k + (i32)1)
            {
            if (w[k] == (u16)13)
                {
                w[k] = (u16)10;
                }
            }
        i32 len = WideCharToMultiByte((u32)CP_UTF8, (u32)0, (pointer)w, n, (pointer)0, (i32)0, (pointer)0, (pointer)0);
        u8* out = (u8*)malloc((u32)len + (u32)1);
        WideCharToMultiByte((u32)CP_UTF8, (u32)0, (pointer)w, n, (pointer)out, len, (pointer)0, (pointer)0);
        out[len] = (u8)0;
        nb[0] = len;
        return out;
        }
    // UTF-8 (LF) to UTF-16 (CR); the caller frees it
    static u16* wideOf(u8* t, i32 nb, i32* n)
        {
        i32 len = nb > (i32)0 ? MultiByteToWideChar((u32)CP_UTF8, (u32)0, (pointer)t, nb, (pointer)0, (i32)0) : (i32)0;
        u16* out = (u16*)malloc((u32)(len + (i32)1) * (u32)2);
        if (len > (i32)0)
            {
            MultiByteToWideChar((u32)CP_UTF8, (u32)0, (pointer)t, nb, (pointer)out, len);
            }
        for (i32 k = (i32)0; k < len; k = k + (i32)1)
            {
            if (out[k] == (u16)10)
                {
                out[k] = (u16)13;
                }
            }
        out[len] = (u16)0;
        n[0] = len;
        return out;
        }
    // a byte offset into UTF-8 t as a UTF-16 index (backed off to a character's start)
    static i32 u16At(u8* t, i32 nb, i32 bytes)
        {
        i32 b = bytes > nb ? nb : bytes;
        if (b <= (i32)0)
            {
            return (i32)0;
            }
        while (b > (i32)0 && b < nb && (t[b] & (u8)$C0) == (u8)$80)
            {
            b = b - (i32)1;
            }
        return MultiByteToWideChar((u32)CP_UTF8, (u32)0, (pointer)t, b, (pointer)0, (i32)0);
        }
    // a UTF-16 index into w as a byte offset (an index inside a surrogate pair counts its start)
    static i32 u8At(u16* w, i32 n, i32 i)
        {
        i32 k = i > n ? n : i;
        if (k <= (i32)0)
            {
            return (i32)0;
            }
        if (k < n && w[k] >= (u16)$DC00 && w[k] < (u16)$E000)
            {
            k = k - (i32)1;
            }
        return WideCharToMultiByte((u32)CP_UTF8, (u32)0, (pointer)w, k, (pointer)0, (i32)0, (pointer)0, (pointer)0);
        }

    // ---- the selection and the styles, in UTF-16 indices ----
    void select(i32 a, i32 b)
        {
        i32 cr[2];
        cr[0] = a;
        cr[1] = b;
        SendMessageA(hwnd, (u32)EM_EXSETSEL, (pointer)0, (pointer)&cr[0]);
        }
    void selection(i32* a, i32* b)
        {
        i32 cr[2];
        cr[0] = (i32)0;
        cr[1] = (i32)0;
        SendMessageA(hwnd, (u32)EM_EXGETSEL, (pointer)0, (pointer)&cr[0]);
        a[0] = cr[0];
        b[0] = cr[1];
        }
    // the selection's character style
    void setFormat(i32 flags, i32 colour, i32 size)
        {
        u8 cf[116];
        self.zero(&cf[0], (i32)116);
        ((u32*)&cf[0])[0] = (u32)116;
        ((u32*)&cf[0])[1] = (u32)CFM_BOLD | (u32)CFM_ITALIC | (u32)CFM_UNDERLINE | (u32)CFM_COLOR | (u32)CFM_SIZE | (u32)CFM_FACE;
        u32 fx = (u32)(flags & (i32)7); // CFE_BOLD 1, CFE_ITALIC 2, CFE_UNDERLINE 4: the same bits
        if ((colour & (i32)$1000000) != (i32)0)
            {
            i32 rgb = colour & (i32)$FFFFFF;
            ((u32*)&cf[0])[5] = (u32)(((rgb >> (i32)16) & (i32)255) | (rgb & (i32)$FF00) | ((rgb & (i32)255) << (i32)16));
            }
        else
            {
            fx = fx | (u32)CFE_AUTOCOLOR;
            }
        ((u32*)&cf[0])[2] = fx;
        ((i32*)&cf[0])[3] = size > (i32)0 ? size * (i32)15 : defHeight; // a pixel is 15 twips at 96 dpi
        u16* face = (u16*)&cf[26];
        if ((flags & (i32)8) != (i32)0)
            {
            u8* mono = (u8*)"Consolas";
            for (i32 k = (i32)0; k < (i32)9; k = k + (i32)1)
                {
                face[k] = (u16)mono[k];
                }
            }
        else
            {
            for (i32 k = (i32)0; k < (i32)32; k = k + (i32)1)
                {
                face[k] = defFace[k];
                }
            }
        SendMessageA(hwnd, (u32)EM_SETCHARFORMAT, (pointer)SCF_SELECTION, (pointer)&cf[0]);
        }
    // the alignment of the paragraphs the selection touches (UX_ALIGN_*)
    void setAlignment(i32 al)
        {
        u8 pf[188];
        self.zero(&pf[0], (i32)188);
        ((u32*)&pf[0])[0] = (u32)188;
        ((u32*)&pf[0])[1] = (u32)PFM_ALIGNMENT;
        ((u16*)&pf[24])[0] = (u16)(al == (i32)1 ? (i32)2 : (al == (i32)2 ? (i32)3 : (al == (i32)3 ? (i32)4 : (i32)1)));
        SendMessageA(hwnd, (u32)EM_SETPARAFORMAT, (pointer)0, (pointer)&pf[0]);
        }
    // the style of [a, b): flags, colour and size, and whether it is the same all through
    bool formatOf(i32 a, i32 b, i32* flags, i32* colour, i32* size)
        {
        self.select(a, b);
        u8 cf[116];
        self.zero(&cf[0], (i32)116);
        ((u32*)&cf[0])[0] = (u32)116;
        SendMessageA(hwnd, (u32)EM_GETCHARFORMAT, (pointer)SCF_SELECTION, (pointer)&cf[0]);
        u32 mask = ((u32*)&cf[0])[1]; // a bit is clear where the range is mixed
        u32 need = (u32)CFM_BOLD | (u32)CFM_ITALIC | (u32)CFM_UNDERLINE | (u32)CFM_COLOR | (u32)CFM_SIZE | (u32)CFM_FACE;
        u32 fx = ((u32*)&cf[0])[2];
        i32 f = (i32)(fx & (u32)7);
        u16* face = (u16*)&cf[26];
        if (face[0] == (u16)'C' && face[1] == (u16)'o' && face[2] == (u16)'n' && face[3] == (u16)'s')
            {
            f = f | (i32)8;
            }
        i32 c = (i32)0;
        if ((fx & (u32)CFE_AUTOCOLOR) == (u32)0)
            {
            i32 bgr = (i32)((u32*)&cf[0])[5];
            c = (i32)$1000000 | ((bgr & (i32)255) << (i32)16) | (bgr & (i32)$FF00) | ((bgr >> (i32)16) & (i32)255);
            }
        i32 yh = ((i32*)&cf[0])[3];
        i32 z = (yh == defHeight) ? (i32)0 : (yh + (i32)7) / (i32)15;
        flags[0] = f;
        colour[0] = c;
        size[0] = z;
        return (mask & need) == need;
        }
    i32 alignmentAt(i32 a)
        {
        self.select(a, a);
        u8 pf[188];
        self.zero(&pf[0], (i32)188);
        ((u32*)&pf[0])[0] = (u32)188;
        SendMessageA(hwnd, (u32)EM_GETPARAFORMAT, (pointer)0, (pointer)&pf[0]);
        i32 wa = (i32)((u16*)&pf[24])[0];
        return wa == (i32)2 ? (i32)1 : (wa == (i32)3 ? (i32)2 : (wa == (i32)4 ? (i32)3 : (i32)0));
        }
    // runs over UTF-8 t applied to the UTF-16 range starting at base (runs are relative to t)
    void applyRuns(u8* t, i32 nb, i32 base, i32* runs, i32 nruns)
        {
        for (i32 k = (i32)0; k < nruns; k = k + (i32)1)
            {
            i32 o = k * (i32)5;
            i32 a = base + W32TextView.u16At(t, nb, runs[o]);
            i32 b = base + W32TextView.u16At(t, nb, runs[o] + runs[o + (i32)1]);
            self.select(a, b);
            self.setFormat(runs[o + (i32)2], runs[o + (i32)3], runs[o + (i32)4]);
            i32 al = (runs[o + (i32)2] >> (i32)4) & (i32)3;
            if (al != (i32)0)
                {
                self.setAlignment(al);
                }
            }
        }

    // ---- the seam ----
    void setAll(u8* text, i32 nb, i32* runs, i32 nruns)
        {
        quiet = quiet + (i32)1;
        SendMessageA(hwnd, (u32)WM_SETREDRAW, (pointer)0, (pointer)0);
        i32 n = (i32)0;
        u16* w = W32TextView.wideOf(text, nb, &n);
        u8 st[8];
        ((u32*)&st[0])[0] = (u32)0; // ST_DEFAULT: the whole content
        ((u32*)&st[0])[1] = (u32)CP_UTF16;
        SendMessageA(hwnd, (u32)EM_SETTEXTEX, (pointer)&st[0], (pointer)w);
        free((pointer)w);
        self.select((i32)0, (i32)-1);
        self.setFormat((i32)0, (i32)0, (i32)0);
        self.setAlignment((i32)0);
        self.applyRuns(text, nb, (i32)0, runs, nruns);
        self.select((i32)0, (i32)0);
        SendMessageA(hwnd, (u32)WM_SETREDRAW, (pointer)1, (pointer)0);
        InvalidateRect(hwnd, (pointer)0, (i32)1);
        quiet = quiet - (i32)1;
        }
    void replace(i32 start, i32 len, u8* text, i32 nb, i32* runs, i32 nruns, i32 attrsOnly)
        {
        quiet = quiet + (i32)1;
        SendMessageA(hwnd, (u32)WM_SETREDRAW, (pointer)0, (pointer)0);
        i32 s0 = (i32)0;
        i32 s1 = (i32)0;
        self.selection(&s0, &s1);
        i32 n = (i32)0;
        u16* w = self.wide(&n);
        i32 cb = (i32)0;
        u8* cur = W32TextView.utf8Of(w, n, &cb);
        i32 a = W32TextView.u16At(cur, cb, start);
        i32 b = W32TextView.u16At(cur, cb, start + len);
        free((pointer)w);
        free((pointer)cur);
        self.select(a, b);
        if (attrsOnly == (i32)0)
            {
            i32 pn = (i32)0;
            u16* pw = W32TextView.wideOf(text, nb, &pn);
            u8 st[8];
            ((u32*)&st[0])[0] = (u32)ST_SELECTION;
            ((u32*)&st[0])[1] = (u32)CP_UTF16;
            SendMessageA(hwnd, (u32)EM_SETTEXTEX, (pointer)&st[0], (pointer)pw);
            free((pointer)pw);
            }
        self.applyRuns(text, nb, a, runs, nruns);
        self.select(s0, s1);
        SendMessageA(hwnd, (u32)WM_SETREDRAW, (pointer)1, (pointer)0);
        InvalidateRect(hwnd, (pointer)0, (i32)1);
        quiet = quiet - (i32)1;
        }
    // the content's UTF-8 and its runs, merged; with runs 0 only counts.  Returns the run count.
    i32 walk(u8* buf, i32 cap, i32* runs, i32 maxRuns, i32* nbytes)
        {
        quiet = quiet + (i32)1;
        SendMessageA(hwnd, (u32)WM_SETREDRAW, (pointer)0, (pointer)0);
        i32 s0 = (i32)0;
        i32 s1 = (i32)0;
        self.selection(&s0, &s1);
        i32 n = (i32)0;
        u16* w = self.wide(&n);
        u16* w2 = (u16*)malloc((u32)(n + (i32)1) * (u32)2);
        for (i32 k = (i32)0; k <= n; k = k + (i32)1)
            {
            w2[k] = w[k];
            }
        i32 tb = (i32)0;
        u8* t = W32TextView.utf8Of(w2, n, &tb); // w2 now has LFs; w keeps the CRs for offsets
        if (buf != (u8*)0)
            {
            i32 m = tb < cap - (i32)1 ? tb : cap - (i32)1;
            for (i32 k = (i32)0; k < m; k = k + (i32)1)
                {
                buf[k] = t[k];
                }
            buf[m] = (u8)0;
            }
        i32 count = (i32)0;
        i32 pf = (i32)-1;
        i32 pc = (i32)0;
        i32 pz = (i32)0;
        i32 ps = (i32)0;
        while (ps < n)
            {
            // one paragraph: [ps, pe), its CR included
            i32 pe = ps;
            while (pe < n && w[pe] != (u16)13)
                {
                pe = pe + (i32)1;
                }
            if (pe < n)
                {
                pe = pe + (i32)1;
                }
            i32 al = self.alignmentAt(ps);
            i32 i = ps;
            while (i < pe)
                {
                // the run from i: the longest uniform [i, lo), found by doubling then halving.
                // A single character is always uniform.
                i32 f = (i32)0;
                i32 c = (i32)0;
                i32 z = (i32)0;
                i32 lo = i + (i32)1;
                i32 hi = (i32)-1; // the shortest end known to be mixed
                i32 step = (i32)2;
                while (hi < (i32)0 && lo < pe)
                    {
                    i32 e = i + step > pe ? pe : i + step;
                    if (self.formatOf(i, e, &f, &c, &z))
                        {
                        lo = e;
                        step = step * (i32)2;
                        }
                    else
                        {
                        hi = e;
                        }
                    }
                while (hi > (i32)0 && hi - lo > (i32)1)
                    {
                    i32 mid = (lo + hi) / (i32)2;
                    if (self.formatOf(i, mid, &f, &c, &z))
                        {
                        lo = mid;
                        }
                    else
                        {
                        hi = mid;
                        }
                    }
                self.formatOf(i, i + (i32)1, &f, &c, &z);
                f = f | (al << (i32)4);
                i32 b0 = W32TextView.u8At(w, n, i);
                i32 b1 = W32TextView.u8At(w, n, lo);
                if (count > (i32)0 && f == pf && c == pc && z == pz)
                    {
                    if (runs != (i32*)0 && count - (i32)1 < maxRuns)
                        {
                        runs[(count - (i32)1) * (i32)5 + (i32)1] = b1 - runs[(count - (i32)1) * (i32)5];
                        }
                    }
                else
                    {
                    if (runs != (i32*)0 && count < maxRuns)
                        {
                        i32 o = count * (i32)5;
                        runs[o] = b0;
                        runs[o + (i32)1] = b1 - b0;
                        runs[o + (i32)2] = f;
                        runs[o + (i32)3] = c;
                        runs[o + (i32)4] = z;
                        }
                    count = count + (i32)1;
                    pf = f;
                    pc = c;
                    pz = z;
                    }
                i = lo;
                }
            ps = pe;
            }
        free((pointer)w);
        free((pointer)w2);
        free((pointer)t);
        self.select(s0, s1);
        SendMessageA(hwnd, (u32)WM_SETREDRAW, (pointer)1, (pointer)0);
        quiet = quiet - (i32)1;
        if (nbytes != (i32*)0)
            {
            nbytes[0] = tb;
            }
        return count;
        }
    void selectionBytes(i32* start, i32* len)
        {
        i32 a = (i32)0;
        i32 b = (i32)0;
        self.selection(&a, &b);
        i32 n = (i32)0;
        u16* w = self.wide(&n);
        i32 x = W32TextView.u8At(w, n, a);
        i32 y = W32TextView.u8At(w, n, b);
        free((pointer)w);
        start[0] = x < y ? x : y;
        len[0] = x < y ? y - x : x - y;
        }
    void setSelectionBytes(i32 start, i32 len)
        {
        i32 n = (i32)0;
        u16* w = self.wide(&n);
        i32 tb = (i32)0;
        u8* t = W32TextView.utf8Of(w, n, &tb);
        i32 a = W32TextView.u16At(t, tb, start);
        i32 b = W32TextView.u16At(t, tb, start + len);
        free((pointer)w);
        free((pointer)t);
        quiet = quiet + (i32)1;
        self.select(a, b);
        SendMessageA(hwnd, (u32)EM_SCROLLCARET, (pointer)0, (pointer)0);
        quiet = quiet - (i32)1;
        }
    // the style typing gets: a RichEdit keeps it for an empty selection until the caret moves
    void setTyping(i32 flags, i32 colour, i32 size)
        {
        quiet = quiet + (i32)1;
        self.setFormat(flags, colour, size);
        quiet = quiet - (i32)1;
        }

    // ---- from the RichEdit ----
    void changed(void)
        {
        if (quiet != (i32)0 || tv == (UXTextView*)0)
            {
            return;
            }
        tv.nativeDidChange();
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    void selected(void)
        {
        if (quiet != (i32)0 || tv == (UXTextView*)0 || !userMoved)
            {
            return;
            }
        userMoved = false;
        tv.nativeDidSelect();
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    void undoKey(bool redo)
        {
        if (tv == (UXTextView*)0)
            {
            return;
            }
        if (redo)
            {
            tv.redo();
            }
        else
            {
            tv.undo();
            }
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    }

pointer UXWin32Proc(pointer hwnd, u32 msg, pointer wp, pointer lp)
    {
    // WM_PRINTCLIENT (anything printing the window into a DC): the same paint, into that DC
    if (msg == (u32)$0318)
        {
        pointer pud = GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA);
        pointer was = gW32CurHdc;
        gW32CurHdc = wp;
        SelectObject(gW32CurHdc, gW32Font);
        if (pud != (pointer)0 && gW32ContentFn != (pointer)0)
            {
            RECT prc;
            GetClientRect(hwnd, (pointer)&prc);
            UXContentFn* pf = (UXContentFn*)gW32ContentFn;
            pf((i32)0, (i32)0, (i32)0, prc.right, prc.bottom, pud);
            }
        gW32CurHdc = was;
        return (pointer)0;
        }
    // Files dragged in from Explorer: each to the app, at the point in the content.
    if (msg == (u32)WM_DROPFILES)
        {
        i32 dh = w32HandleOf(hwnd);
        POINT dp;
        DragQueryPoint(wp, (pointer)&dp);
        u32 nf = DragQueryFileA(wp, (u32)$FFFFFFFF, (pointer)0, (u32)0);
        for (u32 f = (u32)0; f < nf; f = f + (u32)1)
            {
            u8 path[1024];
            DragQueryFileA(wp, f, (pointer)&path[0], (u32)1024);
            if (gApp != (UXApplication*)0)
                {
                gApp.deliverFileDrop(&path[0], dh, dp.x, dp.y);
                }
            }
        DragFinish(wp);
        return (pointer)0;
        }
    // The smallest the window may be made: the content's minimum, grown to the outer size.
    if (msg == (u32)WM_GETMINMAXINFO)
        {
        i32 mh = w32HandleOf(hwnd);
        if (mh > (i32)0 && gW32MinW[mh] > (i32)0)
            {
            RECT mr;
            mr.left = (i32)0;
            mr.top = (i32)0;
            mr.right = gW32MinW[mh];
            mr.bottom = gW32MinH[mh];
            AdjustWindowRect((pointer)&mr, (u32)WS_OVERLAPPEDWINDOW, gW32Menu != (pointer)0 ? (i32)1 : (i32)0);
            MINMAXINFO* mm = (MINMAXINFO*)lp;
            mm.minTrackX = mr.right - mr.left;
            mm.minTrackY = mr.bottom - mr.top;
            return (pointer)0;
            }
        }
    if (msg == (u32)WM_PAINT)
        {
        pointer ud = GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA); // the UXWindow (reverse map)
        PAINTSTRUCT ps;
        gW32CurHdc = BeginPaint(hwnd, (pointer)&ps);
        SelectObject(gW32CurHdc, gW32Font); // the OS UI font for all custom-drawn text (labels, cells)
        if (ud != (pointer)0 && gW32ContentFn != (pointer)0)
            {
            RECT crc;
            GetClientRect(hwnd, (pointer)&crc); // the WHOLE client area, not a fixed guess
            UXContentFn* f = (UXContentFn*)gW32ContentFn;
            f((i32)0, (i32)0, (i32)0, crc.right, crc.bottom, ud);
            }
        EndPaint(hwnd, (pointer)&ps);
        return (pointer)0;
        }
    // A native label/check/radio asks the parent for its text backdrop; hand back the dialog-face grey
    // (transparent text over it) so they blend into the window instead of sitting on a white block.
    // THE CLOSE BOX.  It arrives as WM_SYSCOMMAND/SC_CLOSE, and letting DefWindowProc have it is
    // fatal: DefWindowProc SENDS WM_CLOSE, and a sent message goes straight to this proc and never
    // enters the queue — while the toolkit's close handling lives in nextEvent, which only sees what
    // GetMessage returns.  So DefWindowProc destroyed the window itself, the app never learned, no
    // PostQuitMessage was ever issued, and the run loop waited for ever on a window that was already
    // gone: `make win32` hung on exit and had to be force-quit.  Posting it puts the close back on
    // the queue, where nextEvent turns it into a tagged UXEventClose like any other.
    if (msg == (u32)WM_SYSCOMMAND && (((u32)wp) & (u32)$FFF0) == (u32)SC_CLOSE)
        {
        PostMessageA(hwnd, (u32)WM_CLOSE, (pointer)0, (pointer)0);
        return (pointer)0;
        }
    if (msg == (u32)WM_CTLCOLORSTATIC || msg == (u32)WM_CTLCOLORBTN)
        {
        SetBkColor((pointer)wp, (u32)$00C0C0C0);
        return gW32FaceBrush;
        }
    // A native CONTROL's WM_COMMAND is SENT straight here (not queued like a menu's), so it must be
    // handled in the proc, not nextEvent.  lParam = the control HWND; its neutral widget rides the
    // control's userdata.  A button/check/radio -> mouseDown (fires the action, toggles); an EDIT's
    // EN_CHANGE -> sync the field buffer.
    // A native TOOLBAR / SEGMENTED button: WM_COMMAND, note==BN_CLICKED, lParam=the ToolbarWindow32 whose
    // userdata is the UXToolbar/UXSegmentedControl peer.  The command id encodes the button (segment index
    // / item tag), NOT a node id, so route it here before the node-id path.  Gating on BN_CLICKED keeps the
    // checked casts safe (an EDIT's WM_COMMAND carries an EN_* note and a non-Object userdata).
    if (msg == (u32)WM_COMMAND && lp != (pointer)0 && (((u32)wp >> (u32)16) & (u32)$FFFF) == (u32)BN_CLICKED)
        {
        i32 cid = (i32)((u32)wp & (u32)$FFFF);
        UXControl* pc = (UXControl* ?)(Object*)GetWindowLongPtrA(lp, (i32)GWLP_USERDATA);
        UXSegmentedControl* sg = (UXSegmentedControl* ?)pc;
        if (sg != (UXSegmentedControl*)0)
            {
            sg.applyNativeSelection(cid);
            sg.fire();
            return (pointer)0;
            }
        UXToolbar* tbw = (UXToolbar* ?)pc;
        if (tbw != (UXToolbar*)0)
            {
            tbw.applyNativeItemClick(cid);
            tbw.fire();
            return (pointer)0;
            }
        }
    if (msg == (u32)WM_COMMAND && lp != (pointer)0)
        {
        i32 id = (i32)((u32)wp & (u32)$FFFF);
        if (id >= (i32)W32_CTRL_ID_BASE)
            {
            i32 note = (i32)(((u32)wp >> (u32)16) & (u32)$FFFF);
            // GATE ON THE EXACT NOTIFICATION — an EDIT sends EN_UPDATE/EN_SETFOCUS/… too, and its
            // userdata is a W32Field STRUCT, not an UXControl: casting that to UXControl and calling
            // mouseDown reads a garbage vtable and crashes.  Only EN_CHANGE syncs the field; only
            // BN_CLICKED (0) fires a button/check/radio (whose userdata IS an UXControl).
            W32TextView* rtv = W32TextView.of(lp);
            if (rtv != (W32TextView*)0)
                {
                if (note == (i32)EN_CHANGE)
                    {
                    rtv.changed();
                    }
                return (pointer)0;
                }
            if (note == (i32)EN_CHANGE)
                {
                W32Field* f = (W32Field*)GetWindowLongPtrA(lp, (i32)GWLP_USERDATA);
                if (f != (W32Field*)0)
                    {
                    GetWindowTextA(lp, (pointer)&f.buf[0], f.cap); // sync the buffer first
                    if (f.field != (pointer)0)
                        {
                        ((UXTextField*)f.field).fieldDidChange();
                        }
                    }
                return (pointer)0;
                }
            if (note == (i32)BN_CLICKED)
                {
                UXControl* ctl = (UXControl* ?)(Object*)GetWindowLongPtrA(lp, (i32)GWLP_USERDATA);
                if (ctl != (UXControl*)0)
                    {
                    if (gW32ClickEvent == (UXEvent*)0)
                        {
                        gW32ClickEvent = new UXEvent();
                        }
                    gW32ClickEvent.kind = (u8)UXEventMouseDown;
                    // Position it at the control's centre and announce it to the tap BEFORE acting.
                    // The OS gave us a notification, not a click, but a recorder needs something it
                    // can replay — and a positioned event replays through the ordinary hit test
                    // straight back to this control.  Without this the tap saw nothing on Win32,
                    // because a native control's notification never reaches the app's dispatch.
                    UXRect cf = ctl.absoluteFrame();
                    gW32ClickEvent.x = (i16)((i32)cf.x + (i32)cf.w / (i32)2);
                    gW32ClickEvent.y = (i16)((i32)cf.y + (i32)cf.h / (i32)2);
                    gW32ClickEvent.handle = w32HandleOf(GetParent(lp));
                    if (gEventTap != (callback void(UXEvent * e))0)
                        {
                        gEventTap(gW32ClickEvent);
                        }
                    ctl.mouseDown(gW32ClickEvent); // action runs; effects show on the next display
                    }
                }
            // a native COMBOBOX (popup) picked an item
            if (note == (i32)CBN_SELCHANGE)
                {
                i32 idx = (i32)SendMessageA(lp, (u32)CB_GETCURSEL, (pointer)0, (pointer)0);
                w32ValueChanged(lp, idx);
                }
            return (pointer)0;
            }
        }
    // The native table's selection changed: mirror the ListView's selected rows into the neutral
    // UXTableView (which fires tableSelectionDidChange), exactly as the AppKit shim does.
    if (msg == (u32)WM_NOTIFY)
        {
        NMHDR* nh = (NMHDR*)lp;
        if (nh.code == (u32)EN_SELCHANGE)
            {
            W32TextView* stv = W32TextView.of(nh.hwndFrom);
            if (stv != (W32TextView*)0)
                {
                stv.selected();
                }
            return (pointer)0;
            }
        // A row dragged out of a list (the left button) or a tree (either button): the app's drag
        if (nh.code == (u32)LVN_BEGINDRAG || nh.code == (u32)LVN_BEGINRDRAG)
            {
            UXTableView* dtv = (UXTableView* ?)(Object*)GetWindowLongPtrA(nh.hwndFrom, (i32)GWLP_USERDATA);
            NMLISTVIEW* nl = (NMLISTVIEW*)lp;
            if (dtv != (UXTableView*)0 && dtv.nativeDragsRows() != (i32)0 && nl.iItem >= (i32)0)
                {
                w32RowDrag(nh.hwndFrom, false, dtv.nativeCellText(nl.iItem, (i32)0), nh.code == (u32)LVN_BEGINRDRAG, nl.ptx, nl.pty);
                }
            return (pointer)0;
            }
        if (nh.code == (u32)TVN_BEGINDRAGA || nh.code == (u32)TVN_BEGINRDRAGA)
            {
            UXOutlineView* dov = (UXOutlineView* ?)(Object*)GetWindowLongPtrA(nh.hwndFrom, (i32)GWLP_USERDATA);
            NMTREEVIEW* dnt = (NMTREEVIEW*)lp;
            if (dov != (UXOutlineView*)0)
                {
                w32RowDrag(nh.hwndFrom, true, dov.nativeDragText(dnt.nLParam), nh.code == (u32)TVN_BEGINRDRAGA, dnt.ptx, dnt.pty);
                }
            return (pointer)0;
            }
        if (nh.code == (u32)LVN_ITEMCHANGED)
            {
            // our own write echoing back
            if (gW32SelPush != (i32)0)
                {
                return (pointer)0;
                }
            UXTableView* tv = (UXTableView* ?)(Object*)GetWindowLongPtrA(nh.hwndFrom, (i32)GWLP_USERDATA);
            if (tv != (UXTableView*)0)
                {
                i32 rows[256];
                i32 n = (i32)0;
                i32 idx = (i32)-1;
                for (;;)
                    {
                    idx = (i32)SendMessageA(nh.hwndFrom, (u32)LVM_GETNEXTITEM, (pointer)idx, (pointer)LVNI_SELECTED);
                    if (idx < (i32)0 || n >= (i32)256)
                        {
                        break;
                        }
                    rows[n] = idx;
                    n = n + (i32)1;
                    }
                tv.applyNativeSelection(&rows[0], n);
                }
            return (pointer)0;
            }
        // Native TREE (SysTreeView32 / UXOutlineView): an item expanded/collapsed -> keep the neutral
        // flattened row list in step; the selection changed -> map the item back to a row and fire.
        if (nh.code == (u32)TVN_ITEMEXPANDEDA)
            {
            UXOutlineView* o = (UXOutlineView* ?)(Object*)GetWindowLongPtrA(nh.hwndFrom, (i32)GWLP_USERDATA);
            if (o != (UXOutlineView*)0)
                {
                NMTREEVIEW* nt = (NMTREEVIEW*)lp;
                o.nativeDidExpand(nt.nLParam, nt.action == (u32)TVACT_EXPAND ? (i32)1 : (i32)0);
                }
            return (pointer)0;
            }
        if (nh.code == (u32)TVN_SELCHANGEDA)
            {
            UXOutlineView* o = (UXOutlineView* ?)(Object*)GetWindowLongPtrA(nh.hwndFrom, (i32)GWLP_USERDATA);
            if (o != (UXOutlineView*)0)
                {
                pointer hSel = SendMessageA(nh.hwndFrom, (u32)TVM_GETNEXTITEM, (pointer)TVGN_CARET, (pointer)0);
                if (hSel != (pointer)0)
                    {
                    TVITEM it;
                    w32TvitemInit(&it);
                    it.mask = (u32)(TVIF_PARAM | TVIF_HANDLE);
                    it.hItem = hSel;
                    SendMessageA(nh.hwndFrom, (u32)TVM_GETITEMA, (pointer)0, (pointer)&it);
                    i32 row = o.rowForItem(it.lParam);
                    if (row >= (i32)0)
                        {
                        i32 rr[1];
                        rr[0] = row;
                        o.applyNativeSelection(&rr[0], (i32)1);
                        }
                    }
                }
            return (pointer)0;
            }
        }
    // maybe an UPDOWN (stepper)
    if (msg == (u32)WM_VSCROLL && lp != (pointer)0)
        {
        UXStepper* stp = (UXStepper* ?)(Object*)GetWindowLongPtrA(lp, (i32)GWLP_USERDATA);
        if (stp != (UXStepper*)0)
            {
            // The up-down fires WM_VSCROLL on the arrow press AND again (SB_ENDSCROLL) on release, at the
            // same position — route only the press so the action fires once per click, not twice.
            i32 code = (i32)((u32)wp & (u32)$FFFF);
            if (code != (i32)SB_ENDSCROLL)
                {
                i32 pos = (i32)SendMessageA(lp, (u32)UDM_GETPOS32, (pointer)0, (pointer)0);
                w32ValueChanged(lp, pos);
                }
            return (pointer)0;
            }
        }
    if (msg == (u32)WM_VSCROLL)
        {
        i32 handle = (i32)0;
        for (i32 i = (i32)1; i < gW32NextHandle; i = i + (i32)1)
            {
            if (gW32Hwnds[i] == hwnd)
                {
                handle = i;
                break;
                }
            }
        if (handle != (i32)0)
            {
            i32 code = (i32)((u32)wp & (u32)$FFFF);
            i32 y = gW32ScrollY[handle];
            if (code == (i32)SB_LINEUP)
                {
                y = y - (i32)10;
                }
            else if (code == (i32)SB_LINEDOWN)
                {
                y = y + (i32)10;
                }
            else if (code == (i32)SB_PAGEUP)
                {
                y = y - (i32)50;
                }
            else if (code == (i32)SB_PAGEDOWN)
                {
                y = y + (i32)50;
                }
            else if (code == (i32)SB_THUMBPOSITION || code == (i32)SB_THUMBTRACK)
                {
                y = (i32)(((u32)wp >> (u32)16) & (u32)$FFFF);
                }
            if (y < (i32)0)
                {
                y = (i32)0;
                }
            if (y > gW32ScrollMax[handle])
                {
                y = gW32ScrollMax[handle];
                }
            gW32ScrollY[handle] = y;
            SetScrollPos(hwnd, (i32)SB_VERT, y, (i32)1);
            InvalidateRect(hwnd, (pointer)0, (i32)1);
            UpdateWindow(hwnd);
            }
        return (pointer)0;
        }
    if (msg == (u32)WM_MOUSEWHEEL)
        {
        i32 handle = (i32)0;
        for (i32 i = (i32)1; i < gW32NextHandle; i = i + (i32)1)
            {
            if (gW32Hwnds[i] == hwnd)
                {
                handle = i;
                break;
                }
            }
        if (handle != (i32)0)
            {
            i32 delta = (i32)(((u32)wp >> (u32)16) & (u32)$FFFF); // hi word of wParam...
            // ...as a SIGNED short
            if (delta >= (i32)32768)
                {
                delta = delta - (i32)65536;
                }
            // Windows convention: wheel up (delta > 0) scrolls the content up -> smaller offset.  One
            // notch (120) = three lines; the WM_VSCROLL line step is 10px, so 30px/notch.
            i32 y = gW32ScrollY[handle] - (delta / (i32)120) * (i32)30;
            if (y < (i32)0)
                {
                y = (i32)0;
                }
            if (y > gW32ScrollMax[handle])
                {
                y = gW32ScrollMax[handle];
                }
            gW32ScrollY[handle] = y;
            SetScrollPos(hwnd, (i32)SB_VERT, y, (i32)1);
            InvalidateRect(hwnd, (pointer)0, (i32)1);
            UpdateWindow(hwnd);
            }
        return (pointer)0;
        }
    // a TRACKBAR (slider) sent this, not the window bar
    if (msg == (u32)WM_HSCROLL && lp != (pointer)0)
        {
        i32 pos = (i32)SendMessageA(lp, (u32)TBM_GETPOS, (pointer)0, (pointer)0);
        w32ValueChanged(lp, pos);
        return (pointer)0;
        }
    if (msg == (u32)WM_HSCROLL)
        {
        i32 handle = (i32)0;
        for (i32 i = (i32)1; i < gW32NextHandle; i = i + (i32)1)
            {
            if (gW32Hwnds[i] == hwnd)
                {
                handle = i;
                break;
                }
            }
        if (handle != (i32)0)
            {
            i32 code = (i32)((u32)wp & (u32)$FFFF);
            i32 x = gW32ScrollX[handle];
            if (code == (i32)SB_LINEUP)
                {
                x = x - (i32)10;
                }
            else if (code == (i32)SB_LINEDOWN)
                {
                x = x + (i32)10;
                }
            else if (code == (i32)SB_PAGEUP)
                {
                x = x - (i32)50;
                }
            else if (code == (i32)SB_PAGEDOWN)
                {
                x = x + (i32)50;
                }
            else if (code == (i32)SB_THUMBPOSITION || code == (i32)SB_THUMBTRACK)
                {
                x = (i32)(((u32)wp >> (u32)16) & (u32)$FFFF);
                }
            if (x < (i32)0)
                {
                x = (i32)0;
                }
            if (x > gW32ScrollMaxX[handle])
                {
                x = gW32ScrollMaxX[handle];
                }
            gW32ScrollX[handle] = x;
            SetScrollPos(hwnd, (i32)SB_HORZ, x, (i32)1);
            InvalidateRect(hwnd, (pointer)0, (i32)1);
            UpdateWindow(hwnd);
            }
        return (pointer)0;
        }
    // NB: no PostQuitMessage on WM_DESTROY — that quit the whole app when ANY window closed (a secondary
    // window like the colour picker would terminate the program).  The app decides when to quit (last
    // window -> UXApplication.closeWindow -> stop), and windowDestroy posts the quit only when none remain.
    return DefWindowProcA(hwnd, msg, wp, lp);
    }

// ── the input shield (UXKindShield) ─────────────────────────────────────────
// A child window covering a region, kept top of the sibling z-order, whose only
// job is to take the press and hand it to the parent -- so a click on a design
// surface reaches the toolkit instead of operating the BUTTON under it.
//
// It paints NOTHING (a null class brush, and WM_ERASEBKGND answered "done"), so
// the real controls underneath still show: what is intercepted is the input,
// not the rendering.  The forwarding is the same translation the scroll
// container above does -- child client coords back into the parent's client
// space, which is where the shadow tree's absolute frames live -- and then the
// window's ordinary dispatchMouse hit-tests it like any other click.
//
// NOT VERIFIED ON REAL WINDOWS: written against the Win32 documentation and the
// scroll container's proven pattern, and exercised only as far as wine goes.
// When a Windows box is next to hand, run the appkit-shield scenario here: a
// click on a shielded native button must reach the toolkit and must NOT fire
// the button.
pointer gW32Shield[64]; // the shield child per window handle, so it can be re-raised
pointer UXShield32Proc(pointer hwnd, u32 msg, pointer wp, pointer lp)
    {
    // transparent: leave what is beneath
    if (msg == (u32)WM_ERASEBKGND)
        {
        return (pointer)1;
        }
    if (msg == (u32)WM_LBUTTONDOWN)
        {
        UXView* sh = (UXView* ?)(Object*)GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA);
        pointer par = GetParent(hwnd);
        if (sh != (UXView*)0 && par != (pointer)0)
            {
            u32 lpw = (u32)lp;
            UXRect a = sh.absoluteFrame();
            i32 x = (i32)(i16)lpw + (i32)a.x;
            i32 y = (i32)(i16)(lpw >> (u32)16) + (i32)a.y;
            PostMessageA(par, (u32)WM_LBUTTONDOWN, wp,
                         (pointer)(((u32)y << (u32)16) | ((u32)x & (u32)$FFFF)));
            }
        return (pointer)0;
        }
    return DefWindowProcA(hwnd, msg, wp, lp);
    }

// ── the GL surface (UXKindGLView) ───────────────────────────────────────────
// The seam's split, exactly as on AppKit: this driver owns the SURFACE -- the child
// window, its device context, the pixel format, the swap -- and the app owns the
// renderer.  A GL view that never asks for a context costs nothing: no surface is made
// until the view is realized and no context until makeGL.
//
// THE LOADER LIVES HERE, and that is the whole reason glProc() is on the seam.  The
// toolchain's Win64 import map carries the GDI and USER entry points but NOT opengl32's
// wgl*, and an import that is not in the map does not link.  So the library is opened at
// run time and the entry points are resolved by name -- which is how a GL program finds
// them on this platform in any case, and which keeps the platform out of the renderer.
pointer gW32GlLib;       // opengl32.dll, opened on the first GL view
pointer gW32GlPeer[8];   // the neutral view pointer -> its surface
pointer gW32GlHwnd[8];
pointer gW32GlDc[8];     // the surface's own device context (CS_OWNDC: stable for its life)
pointer gW32GlCtx[8];
i32 gW32GlCount;
i32 gW32GlSwap = (i32)1; // 1 = the swap waits for the display (glSetSwapInterval)
pointer gW32WglCreate;   // wglCreateContext
pointer gW32WglMakeCur;  // wglMakeCurrent
pointer gW32WglDeleteCtx;
pointer gW32WglGetProc;
pointer gW32WglCreateAttribs; // wglCreateContextAttribsARB, or 0 (the core-profile request)
pointer gW32WglSwapInterval;  // wglSwapIntervalEXT, or 0
pointer gW32GlViewport;       // glViewport, resolved with the rest
pointer gW32GlGetInt;         // glGetIntegerv: the GPU's size limits
i32 gW32GlTestMax;            // a test's lower limit on the drawable (0 = the GPU's own)

typedef pointer WglCreateFn(pointer hdc);
typedef pointer WglCreateAttribsFn(pointer hdc, pointer share, i32* attribs);
typedef pointer WglMakeCurFn(pointer hdc, pointer ctx);
typedef i32 WglDeleteCtxFn(pointer ctx);
typedef pointer WglGetProcFn(u8* name);
typedef i32 WglSwapIntervalFn(i32 interval);
typedef void GlViewportFn(i32 x, i32 y, i32 w, i32 h);
typedef void GlGetIntFn(u32 pname, i32* out);

// ── the offscreen surface (the one-surface model, as on AppKit) ───────────────────────────
// The GL never draws to the screen.  It renders into a framebuffer object the driver owns -- the
// renderer's default framebuffer, so it does not know -- and presentGL reads the frame back into a
// bottom-up DIB, which the paint pass blits with StretchDIBits where the GL view sits, in tree
// order.  So a 2-D view after the map in the tree is painted OVER it.  As a visible child window
// it could not be: Windows clips a parent's painting around its children, so nothing the toolkit
// draws can land on the map at all.  The child window stays, HIDDEN, because the pixel format and
// the context belong to a window; a GL with no framebuffer objects keeps it visible and swaps, the
// old plane, rather than draw nothing.
u32 gW32GlFbo[8];
u32 gW32GlRb[8];
pointer gW32GlPx[8];      // the last presented frame, BGRA, bottom-up
i32 gW32GlPW[8];          // its size in pixels
i32 gW32GlPH[8];
i32 gW32GlOff[8];         // 1 = offscreen (hidden child, blitted); 0 = the visible child plane
pointer gW32GenFb;        // glGenFramebuffers ... resolved once, core name or the EXT one
pointer gW32BindFb;
pointer gW32DelFb;
pointer gW32GenRb;
pointer gW32BindRb;
pointer gW32DelRb;
pointer gW32RbStorage;
pointer gW32FbRb;
pointer gW32FbStatus;
pointer gW32ReadPx;
pointer gW32StretchDIBits; // gdi32, by name: it is not in the toolchain's import map
i32 gW32FboTried;
pointer gW32SaveDC;          // a view's clip, by name like the rest: SaveDC / IntersectClipRect / RestoreDC
pointer gW32RestoreDC;
pointer gW32IntersectClip;
typedef i32 W32SaveDCFn(pointer hdc);
typedef i32 W32RestoreDCFn(pointer hdc, i32 n);
typedef i32 W32IntersectClipFn(pointer hdc, i32 l, i32 t, i32 r, i32 b);
typedef void W32GlGenFn(i32 n, u32* out);
typedef void W32GlBindFn(u32 target, u32 id);
typedef void W32GlRbStorageFn(u32 target, u32 fmt, i32 w, i32 h);
typedef void W32GlFbRbFn(u32 target, u32 att, u32 rbtarget, u32 rb);
typedef u32 W32GlStatusFn(u32 target);
typedef void W32GlReadPixelsFn(i32 x, i32 y, i32 w, i32 h, u32 fmt, u32 type, pointer px);
typedef i32 W32StretchDIBitsFn(pointer hdc, i32 xd, i32 yd, i32 wd, i32 hd, i32 xs, i32 ys, i32 ws,
                               i32 hs, pointer bits, pointer bmi, u32 usage, u32 rop);
struct W32BmiHeader
    {
    u32 biSize;
    i32 biWidth;
    i32 biHeight;
    u16 biPlanes;
    u16 biBitCount;
    u32 biCompression;
    u32 biSizeImage;
    i32 biXPelsPerMeter;
    i32 biYPelsPerMeter;
    u32 biClrUsed;
    u32 biClrImportant;
    }

// The window snapshot's GDI and user32 calls, by name like StretchDIBits.
pointer gW32CreateDIBSection;
pointer gW32BitBlt;
i32 gW32SnapLoaded;
i32 gW32UnderWine; // Wine keeps a surface per window, and its controls ignore WM_PRINT
pointer gW32PrintWindow;
pointer gW32GetWindow;
pointer gW32IsVisible;
typedef i32 W32PrintWindowFn(pointer hwnd, pointer hdc, u32 flags);
typedef pointer W32GetWindowFn(pointer hwnd, u32 cmd);
typedef i32 W32IsVisibleFn(pointer hwnd);
typedef pointer W32CreateDIBSectionFn(pointer hdc, pointer bmi, u32 usage, pointer* bits, pointer section, u32 offset);
typedef i32 W32BitBltFn(pointer hdc, i32 x, i32 y, i32 w, i32 h, pointer src, i32 sx, i32 sy, u32 rop);
void w32_snap_load(void)
    {
    if (gW32SnapLoaded != (i32)0)
        {
        return;
        }
    gW32SnapLoaded = (i32)1;
    pointer gdi = LoadLibraryA((pointer)"gdi32.dll");
    pointer usr = LoadLibraryA((pointer)"user32.dll");
    if (gdi != (pointer)0)
        {
        gW32CreateDIBSection = GetProcAddress(gdi, (u8*)"CreateDIBSection");
        gW32BitBlt = GetProcAddress(gdi, (u8*)"BitBlt");
        }
    if (usr != (pointer)0)
        {
        gW32PrintWindow = GetProcAddress(usr, (u8*)"PrintWindow");
        gW32GetWindow = GetProcAddress(usr, (u8*)"GetWindow");
        gW32IsVisible = GetProcAddress(usr, (u8*)"IsWindowVisible");
        }
    pointer nt = LoadLibraryA((pointer)"ntdll.dll");
    gW32UnderWine = nt != (pointer)0 && GetProcAddress(nt, (u8*)"wine_get_version") != (pointer)0 ? (i32)1 : (i32)0;
    }
// Copy each visible child window's rectangle from `composed` (the compositor's picture of root's
// client, cw x ch words) into `out` (the driver's own render): the child controls as they painted
// themselves.  Windows' controls will not paint into another DC (WM_PRINT), but the compositor holds
// what they painted.
void w32SnapChildren(pointer root, u32* composed, u32* out, i32 cw, i32 ch)
    {
    if (gW32GetWindow == (pointer)0 || gW32IsVisible == (pointer)0)
        {
        return;
        }
    W32GetWindowFn* gw = (W32GetWindowFn*)gW32GetWindow;
    W32IsVisibleFn* vis = (W32IsVisibleFn*)gW32IsVisible;
    pointer c = gw(root, (u32)5); // GW_CHILD
    while (c != (pointer)0)
        {
        if (vis(c) != (i32)0)
            {
            RECT wr;
            GetWindowRect(c, (pointer)&wr);
            POINT tl;
            tl.x = wr.left;
            tl.y = wr.top;
            ScreenToClient(root, (pointer)&tl);
            i32 x0 = tl.x < (i32)0 ? (i32)0 : tl.x;
            i32 y0 = tl.y < (i32)0 ? (i32)0 : tl.y;
            i32 x1 = tl.x + (wr.right - wr.left) < cw ? tl.x + (wr.right - wr.left) : cw;
            i32 y1 = tl.y + (wr.bottom - wr.top) < ch ? tl.y + (wr.bottom - wr.top) : ch;
            for (i32 y = y0; y < y1; y = y + (i32)1)
                {
                for (i32 x = x0; x < x1; x = x + (i32)1)
                    {
                    out[y * cw + x] = composed[y * cw + x];
                    }
                }
            }
        c = gw(c, (u32)2); // GW_HWNDNEXT
        }
    }

// Open opengl32 and resolve what the DRIVER needs.  wglGetProcAddress is the documented way
// to reach the extension entry points (the core-profile request, the swap interval); the
// base ones opengl32 exports by name and GetProcAddress finds them.
void w32_gl_load(void)
    {
    if (gW32GlLib != (pointer)0)
        {
        return;
        }
    gW32GlLib = LoadLibraryA((pointer)"opengl32.dll");
    if (gW32GlLib == (pointer)0)
        {
        return;
        }
    gW32WglCreate = GetProcAddress(gW32GlLib, (u8*)"wglCreateContext");
    gW32WglMakeCur = GetProcAddress(gW32GlLib, (u8*)"wglMakeCurrent");
    gW32WglDeleteCtx = GetProcAddress(gW32GlLib, (u8*)"wglDeleteContext");
    gW32WglGetProc = GetProcAddress(gW32GlLib, (u8*)"wglGetProcAddress");
    gW32GlViewport = GetProcAddress(gW32GlLib, (u8*)"glViewport");
    gW32GlGetInt = GetProcAddress(gW32GlLib, (u8*)"glGetIntegerv");
    if (gW32WglGetProc != (pointer)0)
        {
        WglGetProcFn* g = (WglGetProcFn*)gW32WglGetProc;
        gW32WglCreateAttribs = g((u8*)"wglCreateContextAttribsARB");
        gW32WglSwapInterval = g((u8*)"wglSwapIntervalEXT");
        }
    }

i32 w32_gl_find(pointer peer)
    {
    for (i32 i = (i32)0; i < gW32GlCount; i = i + (i32)1)
        {
        if (gW32GlPeer[i] == peer)
            {
            return i;
            }
        }
    return (i32)-1;
    }

// The viewport belongs to the driver here as it does everywhere: it is the drawable's size
// in pixels, and on this backend the client rect IS in pixels (there is no point/pixel
// split to reconcile).  Called when the context is made and again whenever the surface
// moves or resizes, so a renderer never sets one and never asks what it is.
void w32_gl_viewport(pointer peer)
    {
    i32 i = w32_gl_find(peer);
    if (i < (i32)0 || gW32GlCtx[i] == (pointer)0 || gW32GlViewport == (pointer)0 || gW32WglMakeCur == (pointer)0)
        {
        return;
        }
    WglMakeCurFn* mc = (WglMakeCurFn*)gW32WglMakeCur;
    if (mc(gW32GlDc[i], gW32GlCtx[i]) == (pointer)0)
        {
        return;
        }
    RECT r;
    r.left = (i32)0;
    r.top = (i32)0;
    r.right = (i32)0;
    r.bottom = (i32)0;
    GetClientRect(gW32GlHwnd[i], (pointer)&r);
    i32 w = r.right - r.left;
    i32 hh = r.bottom - r.top;
    // Offscreen, the drawable is the framebuffer, which may have been clamped below the view's size.
    if (gW32GlOff[i] != (i32)0 && gW32GlPW[i] > (i32)0)
        {
        w = gW32GlPW[i];
        hh = gW32GlPH[i];
        }
    if (w < (i32)1)
        {
        w = (i32)1;
        }
    if (hh < (i32)1)
        {
        hh = (i32)1;
        }
    GlViewportFn* vp = (GlViewportFn*)gW32GlViewport;
    vp((i32)0, (i32)0, w, hh);
    }

// An extension entry point by its core name, or its EXT name (a 2.1 context has only the latter).
pointer w32_gl_ext(u8* core, u8* ext)
    {
    pointer p = (pointer)0;
    if (gW32WglGetProc != (pointer)0)
        {
        WglGetProcFn* g = (WglGetProcFn*)gW32WglGetProc;
        p = g(core);
        if (p == (pointer)0)
            {
            p = g(ext);
            }
        }
    return p;
    }
// The framebuffer entry points, resolved once with a context current (wglGetProcAddress needs one).
void w32_gl_fbo_load(void)
    {
    if (gW32FboTried != (i32)0)
        {
        return;
        }
    gW32FboTried = (i32)1;
    gW32GenFb = w32_gl_ext((u8*)"glGenFramebuffers", (u8*)"glGenFramebuffersEXT");
    gW32BindFb = w32_gl_ext((u8*)"glBindFramebuffer", (u8*)"glBindFramebufferEXT");
    gW32DelFb = w32_gl_ext((u8*)"glDeleteFramebuffers", (u8*)"glDeleteFramebuffersEXT");
    gW32GenRb = w32_gl_ext((u8*)"glGenRenderbuffers", (u8*)"glGenRenderbuffersEXT");
    gW32BindRb = w32_gl_ext((u8*)"glBindRenderbuffer", (u8*)"glBindRenderbufferEXT");
    gW32DelRb = w32_gl_ext((u8*)"glDeleteRenderbuffers", (u8*)"glDeleteRenderbuffersEXT");
    gW32RbStorage = w32_gl_ext((u8*)"glRenderbufferStorage", (u8*)"glRenderbufferStorageEXT");
    gW32FbRb = w32_gl_ext((u8*)"glFramebufferRenderbuffer", (u8*)"glFramebufferRenderbufferEXT");
    gW32FbStatus = w32_gl_ext((u8*)"glCheckFramebufferStatus", (u8*)"glCheckFramebufferStatusEXT");
    gW32ReadPx = GetProcAddress(gW32GlLib, (u8*)"glReadPixels");
    pointer gdi = LoadLibraryA((pointer)"gdi32.dll");
    if (gdi != (pointer)0)
        {
        gW32StretchDIBits = GetProcAddress(gdi, (u8*)"StretchDIBits");
        }
    }
i32 w32_gl_has_fbo(void)
    {
    return gW32GenFb != (pointer)0 && gW32BindFb != (pointer)0 && gW32GenRb != (pointer)0 && gW32BindRb != (pointer)0
        && gW32RbStorage != (pointer)0 && gW32FbRb != (pointer)0 && gW32FbStatus != (pointer)0
        && gW32ReadPx != (pointer)0 && gW32StretchDIBits != (pointer)0 ? (i32)1 : (i32)0;
    }
void w32_gl_free_offscreen(i32 i)
    {
    if (gW32GlFbo[i] != (u32)0 && gW32DelFb != (pointer)0)
        {
        W32GlGenFn* d = (W32GlGenFn*)gW32DelFb; // same shape: (n, ids)
        d((i32)1, &gW32GlFbo[i]);
        }
    if (gW32GlRb[i] != (u32)0 && gW32DelRb != (pointer)0)
        {
        W32GlGenFn* d = (W32GlGenFn*)gW32DelRb;
        d((i32)1, &gW32GlRb[i]);
        }
    if (gW32GlPx[i] != (pointer)0)
        {
        free(gW32GlPx[i]);
        }
    gW32GlFbo[i] = (u32)0;
    gW32GlRb[i] = (u32)0;
    gW32GlPx[i] = (pointer)0;
    gW32GlPW[i] = (i32)0;
    gW32GlPH[i] = (i32)0;
    }
// The largest drawable the current context can render: a renderbuffer and a viewport must both
// hold it (GL_MAX_RENDERBUFFER_SIZE, GL_MAX_VIEWPORT_DIMS), and the texture limit is the one an old
// integrated GPU runs out of first (GL_MAX_TEXTURE_SIZE).  0 = unknown.
i32 w32_gl_max_px()
    {
    i32 m = (i32)0;
    if (gW32GlGetInt != (pointer)0)
        {
        GlGetIntFn* gi = (GlGetIntFn*)gW32GlGetInt;
        i32 v[2];
        v[0] = (i32)0;
        v[1] = (i32)0;
        gi((u32)$0D33, &v[0]); // GL_MAX_TEXTURE_SIZE
        m = v[0];
        v[0] = (i32)0;
        gi((u32)$84E8, &v[0]); // GL_MAX_RENDERBUFFER_SIZE
        if (v[0] > (i32)0 && (m <= (i32)0 || v[0] < m)) { m = v[0]; }
        v[0] = (i32)0;
        v[1] = (i32)0;
        gi((u32)$0D3A, &v[0]); // GL_MAX_VIEWPORT_DIMS
        if (v[0] > (i32)0 && (m <= (i32)0 || v[0] < m)) { m = v[0]; }
        if (v[1] > (i32)0 && (m <= (i32)0 || v[1] < m)) { m = v[1]; }
        }
    if (gW32GlTestMax > (i32)0 && (m <= (i32)0 || gW32GlTestMax < m))
        {
        m = gW32GlTestMax;
        }
    return m;
    }
// Make (or remake at the child window's client size) the framebuffer the renderer draws into, and
// leave it bound.  A size beyond the GPU's limit (a maximised window at 150-200% scaling on an old
// integrated GPU, or one stretched across two monitors) is scaled down by one factor on both sides,
// keeping the aspect; the paint's StretchDIBits stretches the frame back over the view.  1 on success; 0 = no framebuffer objects here, keep the visible plane.
i32 w32_gl_offscreen(i32 i)
    {
    w32_gl_fbo_load();
    if (w32_gl_has_fbo() == (i32)0)
        {
        return (i32)0;
        }
    RECT r;
    GetClientRect(gW32GlHwnd[i], (pointer)&r);
    i32 w = (i32)(r.right - r.left);
    i32 h = (i32)(r.bottom - r.top);
    i32 m = w32_gl_max_px();
    if (m > (i32)0 && (w > m || h > m))
        {
        if (w >= h)
            {
            h = (h * m) / w;
            w = m;
            }
        else
            {
            w = (w * m) / h;
            h = m;
            }
        }
    if (w < (i32)1) { w = (i32)1; }
    if (h < (i32)1) { h = (i32)1; }
    W32GlBindFn* bind = (W32GlBindFn*)gW32BindFb;
    if (gW32GlFbo[i] != (u32)0 && gW32GlPW[i] == w && gW32GlPH[i] == h)
        {
        bind((u32)$8D40, gW32GlFbo[i]); // GL_FRAMEBUFFER
        return (i32)1;
        }
    w32_gl_free_offscreen(i);
    W32GlGenFn* genRb = (W32GlGenFn*)gW32GenRb;
    W32GlBindFn* bindRb = (W32GlBindFn*)gW32BindRb;
    W32GlRbStorageFn* store = (W32GlRbStorageFn*)gW32RbStorage;
    W32GlGenFn* genFb = (W32GlGenFn*)gW32GenFb;
    W32GlFbRbFn* attach = (W32GlFbRbFn*)gW32FbRb;
    W32GlStatusFn* status = (W32GlStatusFn*)gW32FbStatus;
    genRb((i32)1, &gW32GlRb[i]);
    bindRb((u32)$8D41, gW32GlRb[i]);                 // GL_RENDERBUFFER
    store((u32)$8D41, (u32)$8058, w, h);             // GL_RGBA8
    genFb((i32)1, &gW32GlFbo[i]);
    bind((u32)$8D40, gW32GlFbo[i]);
    attach((u32)$8D40, (u32)$8CE0, (u32)$8D41, gW32GlRb[i]); // COLOR_ATTACHMENT0
    if (status((u32)$8D40) != (u32)$8CD5)                    // FRAMEBUFFER_COMPLETE
        {
        bind((u32)$8D40, (u32)0);
        w32_gl_free_offscreen(i);
        return (i32)0;
        }
    gW32GlPx[i] = malloc((u32)(w * h * (i32)4));
    gW32GlPW[i] = w;
    gW32GlPH[i] = h;
    return (i32)1;
    }
// Paint a GL view's last presented frame into the paint in flight, at (x,y,w,h).  1 if it drew.
i32 w32_gl_blit(pointer peer, i32 x, i32 y, i32 w, i32 h)
    {
    i32 i = w32_gl_find(peer);
    if (i < (i32)0 || gW32GlOff[i] == (i32)0 || gW32GlPx[i] == (pointer)0 || gW32CurHdc == (pointer)0)
        {
        return (i32)0;
        }
    W32BmiHeader bmi;
    bmi.biSize = (u32)40;
    bmi.biWidth = gW32GlPW[i];
    bmi.biHeight = gW32GlPH[i]; // positive: bottom-up, which is the order glReadPixels returns
    bmi.biPlanes = (u16)1;
    bmi.biBitCount = (u16)32;
    bmi.biCompression = (u32)0; // BI_RGB
    bmi.biSizeImage = (u32)0;
    bmi.biXPelsPerMeter = (i32)0;
    bmi.biYPelsPerMeter = (i32)0;
    bmi.biClrUsed = (u32)0;
    bmi.biClrImportant = (u32)0;
    W32StretchDIBitsFn* sd = (W32StretchDIBitsFn*)gW32StretchDIBits;
    sd(gW32CurHdc, x, y, w, h, (i32)0, (i32)0, gW32GlPW[i], gW32GlPH[i], gW32GlPx[i], (pointer)&bmi,
       (u32)0, (u32)$00CC0020); // DIB_RGB_COLORS, SRCCOPY
    return (i32)1;
    }

// Take the surface: a device context of its own and the pixel format chosen for it.  The
// format is set ONCE per window -- the OS permits no second SetPixelFormat -- which is why
// it happens at realization and the context at makeGL.
void w32_gl_attach(pointer peer, pointer hwnd)
    {
    w32_gl_load();
    if (gW32GlLib == (pointer)0 || gW32GlCount >= (i32)8)
        {
        return;
        }
    // Key the surface on the NEUTRAL VIEW, which is what makeGLContext is handed and the
    // only handle it has.  A plain view registers no peer, so the FIRST realization -- the
    // one that happens before makeGL -- arrives here with none; the surface is taken on
    // the realization that FOLLOWS makeGL, and it is taken ONCE per view.  So this is
    // find-or-create by peer and a no-op once the peer has one.
    if (peer == (pointer)0 || w32_gl_find(peer) >= (i32)0)
        {
        return;
        }
    pointer dc = GetDC(hwnd);
    if (dc == (pointer)0)
        {
        return;
        }
    PIXELFORMATDESCRIPTOR pfd;
    pfd.nSize = (u16)sizeof(PIXELFORMATDESCRIPTOR);
    pfd.nVersion = (u16)1;
    pfd.dwFlags = (u32)PFD_DRAW_TO_WINDOW | (u32)PFD_SUPPORT_OPENGL | (u32)PFD_DOUBLEBUFFER;
    pfd.iPixelType = (u8)PFD_TYPE_RGBA;
    pfd.iColorBits = (u8)24;
    pfd.iRedBits = (u8)0; pfd.iRedShift = (u8)0;
    pfd.iGreenBits = (u8)0; pfd.iGreenShift = (u8)0;
    pfd.iBlueBits = (u8)0; pfd.iBlueShift = (u8)0;
    pfd.iAlphaBits = (u8)8; pfd.iAlphaShift = (u8)0;
    pfd.iAccumBits = (u8)0; pfd.iAccumRedBits = (u8)0; pfd.iAccumGreenBits = (u8)0;
    pfd.iAccumBlueBits = (u8)0; pfd.iAccumAlphaBits = (u8)0;
    pfd.iDepthBits = (u8)0;
    pfd.iStencilBits = (u8)0;
    pfd.iAuxBuffers = (u8)0;
    pfd.iLayerType = (u8)0;
    pfd.bReserved = (u8)0;
    pfd.dwLayerMask = (u32)0;
    pfd.dwVisibleMask = (u32)0;
    pfd.dwDamageMask = (u32)0;
    i32 fmt = ChoosePixelFormat(dc, (pointer)&pfd);
    if (fmt == (i32)0 || SetPixelFormat(dc, fmt, (pointer)&pfd) == (i32)0)
        {
        ReleaseDC(hwnd, dc);
        return; // no surface: the view keeps its drawRect fallback
        }
    i32 i = gW32GlCount;
    gW32GlPeer[i] = peer;
    gW32GlHwnd[i] = hwnd;
    gW32GlDc[i] = dc;
    gW32GlCtx[i] = (pointer)0;
    gW32GlCount = i + (i32)1;
    }

// The GL surface window.  It erases nothing (the swap has already put the picture up, and
// erasing would flash the background between frames) and paints nothing (the app draws into
// the surface, not the toolkit).  A press is translated to the parent's coordinates and
// posted there, the same forwarding the input shield does, so a click on the map reaches
// the toolkit's own hit-test.
pointer UXGl32Proc(pointer hwnd, u32 msg, pointer wp, pointer lp)
    {
    if (msg == (u32)WM_ERASEBKGND)
        {
        return (pointer)1;
        }
    if (msg == (u32)WM_PAINT)
        {
        return (pointer)0;
        }
    if (msg == (u32)WM_LBUTTONDOWN)
        {
        UXView* gv = (UXView* ?)(Object*)GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA);
        pointer par = GetParent(hwnd);
        if (gv != (UXView*)0 && par != (pointer)0)
            {
            u32 lpw = (u32)lp;
            UXRect a = gv.absoluteFrame();
            i32 x = (i32)(i16)lpw + (i32)a.x;
            i32 y = (i32)(i16)(lpw >> (u32)16) + (i32)a.y;
            PostMessageA(par, (u32)WM_LBUTTONDOWN, wp,
                         (pointer)(((u32)y << (u32)16) | ((u32)x & (u32)$FFFF)));
            }
        return (pointer)0;
        }
    return DefWindowProcA(hwnd, msg, wp, lp);
    }

// ---- sound (UXSound.play) ------------------------------------------------------------------
// One waveOut stream per sound: Windows mixes concurrent streams, so sounds overlap.  The samples are
// copied into the stream's own buffer; a finished stream (WHDR_DONE) is closed and freed on the next
// play.  winmm's entry points are resolved by name, as the other extras are.
struct W32WaveFormat
    {
    u16 wFormatTag;
    u16 nChannels;
    u32 nSamplesPerSec;
    u32 nAvgBytesPerSec;
    u16 nBlockAlign;
    u16 wBitsPerSample;
    u16 cbSize;
    }
struct W32WaveHdr
    {
    pointer lpData;
    u32 dwBufferLength;
    u32 dwBytesRecorded;
    pointer dwUser;
    u32 dwFlags;
    u32 dwLoops;
    pointer lpNext;
    pointer reserved;
    }
typedef u32 W32WaveOpenFn(pointer* hwo, u32 dev, pointer fmt, pointer cb, pointer inst, u32 flags);
typedef u32 W32WaveHdrFn(pointer hwo, pointer hdr, u32 size);
typedef u32 W32WaveCloseFn(pointer hwo);
#define W32_MAXSOUNDS 32
pointer gW32WaveOut[32];      // the open streams (0 = free slot)
W32WaveHdr* gW32WaveHdr[32];  // their headers (malloc'd, as the samples are)
pointer gW32WinMM;
// Close and free every stream that has finished.  Returns how many are still playing.
i32 w32_sound_prune()
    {
    if (gW32WinMM == (pointer)0)
        {
        return (i32)0;
        }
    W32WaveHdrFn* unprep = (W32WaveHdrFn*)GetProcAddress(gW32WinMM, (u8*)"waveOutUnprepareHeader");
    W32WaveCloseFn* close = (W32WaveCloseFn*)GetProcAddress(gW32WinMM, (u8*)"waveOutClose");
    i32 live = (i32)0;
    for (i32 k = (i32)0; k < (i32)W32_MAXSOUNDS; k = k + (i32)1)
        {
        if (gW32WaveOut[k] == (pointer)0)
            {
            continue;
            }
        W32WaveHdr* hd = gW32WaveHdr[k];
        if ((hd.dwFlags & (u32)1) == (u32)0) // WHDR_DONE
            {
            live = live + (i32)1;
            continue;
            }
        unprep(gW32WaveOut[k], (pointer)hd, (u32)48);
        close(gW32WaveOut[k]);
        free(hd.lpData);
        free((pointer)hd);
        gW32WaveOut[k] = (pointer)0;
        gW32WaveHdr[k] = (W32WaveHdr*)0;
        }
    return live;
    }
bool w32_sound_play(i16* pcm, i32 frames, i32 rate)
    {
    if (gW32WinMM == (pointer)0)
        {
        gW32WinMM = LoadLibraryA((pointer)"winmm.dll");
        if (gW32WinMM == (pointer)0)
            {
            return false;
            }
        }
    w32_sound_prune();
    i32 slot = (i32)-1;
    for (i32 k = (i32)0; k < (i32)W32_MAXSOUNDS && slot < (i32)0; k = k + (i32)1)
        {
        if (gW32WaveOut[k] == (pointer)0)
            {
            slot = k;
            }
        }
    W32WaveOpenFn* open = (W32WaveOpenFn*)GetProcAddress(gW32WinMM, (u8*)"waveOutOpen");
    W32WaveHdrFn* prep = (W32WaveHdrFn*)GetProcAddress(gW32WinMM, (u8*)"waveOutPrepareHeader");
    W32WaveHdrFn* write = (W32WaveHdrFn*)GetProcAddress(gW32WinMM, (u8*)"waveOutWrite");
    W32WaveCloseFn* close = (W32WaveCloseFn*)GetProcAddress(gW32WinMM, (u8*)"waveOutClose");
    if (slot < (i32)0 || open == (W32WaveOpenFn*)0 || prep == (W32WaveHdrFn*)0 || write == (W32WaveHdrFn*)0)
        {
        return false;
        }
    W32WaveFormat fmt;
    fmt.wFormatTag = (u16)1; // PCM
    fmt.nChannels = (u16)1;
    fmt.nSamplesPerSec = (u32)rate;
    fmt.nAvgBytesPerSec = (u32)(rate * (i32)2);
    fmt.nBlockAlign = (u16)2;
    fmt.wBitsPerSample = (u16)16;
    fmt.cbSize = (u16)0;
    pointer hwo = (pointer)0;
    if (open(&hwo, (u32)$FFFFFFFF, (pointer)&fmt, (pointer)0, (pointer)0, (u32)0) != (u32)0) // WAVE_MAPPER, CALLBACK_NULL
        {
        return false;
        }
    u8* data = (u8*)malloc((u32)(frames * (i32)2));
    u8* src = (u8*)pcm;
    for (i32 i = (i32)0; i < frames * (i32)2; i = i + (i32)1)
        {
        data[i] = src[i];
        }
    W32WaveHdr* hd = (W32WaveHdr*)calloc((u32)1, (u32)48);
    hd.lpData = (pointer)data;
    hd.dwBufferLength = (u32)(frames * (i32)2);
    if (prep(hwo, (pointer)hd, (u32)48) != (u32)0 || write(hwo, (pointer)hd, (u32)48) != (u32)0)
        {
        close(hwo);
        free((pointer)data);
        free((pointer)hd);
        return false;
        }
    gW32WaveOut[slot] = hwo;
    gW32WaveHdr[slot] = hd;
    return true;
    }

// ---- the application icon (UXApplication.setIcon) -------------------------------------------
// An HICON from a 32-bit DIB section with its alpha (Windows Vista on draws icon alpha straight), set
// as both the big icon (taskbar, Alt-Tab) and the small one (title bar) on every window, and kept so a
// window opened later gets it too.  The entry points are resolved by name, as the paint path does,
// because they are not in the toolchain's import map.
struct W32IconInfo
    {
    i32 fIcon;
    u32 xHotspot;
    u32 yHotspot;
    pointer hbmMask;
    pointer hbmColor;
    }
typedef pointer W32CreateDIBFn(pointer hdc, pointer bmi, u32 usage, pointer* bits, pointer section, u32 offset);
typedef pointer W32CreateBitmapFn(i32 w, i32 h, u32 planes, u32 bpp, pointer bits);
typedef pointer W32CreateIconFn(pointer info);
typedef i32 W32DestroyIconFn(pointer icon);
typedef pointer W32SHGetFileInfoWFn(pointer path, u32 attrs, pointer info, u32 cb, u32 flags);
// shell32's SHGetFileInfoW and user32's DestroyIcon, looked up as appSetIcon does
pointer w32SHGetFileInfoW(pointer path, u32 attrs, pointer info, u32 cb, u32 flags)
    {
    W32SHGetFileInfoWFn* f = (W32SHGetFileInfoWFn*)GetProcAddress(LoadLibraryA((pointer)"shell32.dll"), (u8*)"SHGetFileInfoW");
    return f != (W32SHGetFileInfoWFn*)0 ? f(path, attrs, info, cb, flags) : (pointer)0;
    }
void w32DestroyIcon(pointer icon)
    {
    W32DestroyIconFn* d = (W32DestroyIconFn*)GetProcAddress(LoadLibraryA((pointer)"user32.dll"), (u8*)"DestroyIcon");
    if (d != (W32DestroyIconFn*)0)
        {
        d(icon);
        }
    }
pointer gW32AppIcon;
pointer w32_app_icon_make(u8* data, i32 w, i32 h, i32 fmt)
    {
    pointer gdi = LoadLibraryA((pointer)"gdi32.dll");
    pointer usr = LoadLibraryA((pointer)"user32.dll");
    if (gdi == (pointer)0 || usr == (pointer)0)
        {
        return (pointer)0;
        }
    W32CreateDIBFn* mkDib = (W32CreateDIBFn*)GetProcAddress(gdi, (u8*)"CreateDIBSection");
    W32CreateBitmapFn* mkBmp = (W32CreateBitmapFn*)GetProcAddress(gdi, (u8*)"CreateBitmap");
    W32CreateIconFn* mkIcon = (W32CreateIconFn*)GetProcAddress(usr, (u8*)"CreateIconIndirect");
    if (mkDib == (W32CreateDIBFn*)0 || mkBmp == (W32CreateBitmapFn*)0 || mkIcon == (W32CreateIconFn*)0)
        {
        return (pointer)0;
        }
    W32BmiHeader bmi;
    bmi.biSize = (u32)40;
    bmi.biWidth = w;
    bmi.biHeight = (i32)0 - h; // negative: top-down, as the pixels are
    bmi.biPlanes = (u16)1;
    bmi.biBitCount = (u16)32;
    bmi.biCompression = (u32)0;
    bmi.biSizeImage = (u32)0;
    bmi.biXPelsPerMeter = (i32)0;
    bmi.biYPelsPerMeter = (i32)0;
    bmi.biClrUsed = (u32)0;
    bmi.biClrImportant = (u32)0;
    pointer bits = (pointer)0;
    pointer color = mkDib((pointer)0, (pointer)&bmi, (u32)0, &bits, (pointer)0, (u32)0);
    if (color == (pointer)0 || bits == (pointer)0)
        {
        return (pointer)0;
        }
    u8* out = (u8*)bits; // B, G, R, A per pixel
    for (i32 k = (i32)0; k < w * h; k = k + (i32)1)
        {
        u8* q = data + k * (i32)4;
        out[k * (i32)4] = fmt == (i32)1 ? q[0] : q[2];
        out[k * (i32)4 + (i32)1] = q[1];
        out[k * (i32)4 + (i32)2] = fmt == (i32)1 ? q[2] : q[0];
        out[k * (i32)4 + (i32)3] = q[3];
        }
    pointer mask = mkBmp(w, h, (u32)1, (u32)1, (pointer)0); // all zero: the alpha does the masking
    W32IconInfo ii;
    ii.fIcon = (i32)1;
    ii.xHotspot = (u32)0;
    ii.yHotspot = (u32)0;
    ii.hbmMask = mask;
    ii.hbmColor = color;
    pointer icon = mkIcon((pointer)&ii);
    DeleteObject(color); // the icon holds its own copies
    DeleteObject(mask);
    return icon;
    }
void w32_app_icon_apply(pointer hwnd)
    {
    if (gW32AppIcon != (pointer)0 && hwnd != (pointer)0)
        {
        SendMessageA(hwnd, (u32)$0080, (pointer)1, gW32AppIcon); // WM_SETICON, ICON_BIG
        SendMessageA(hwnd, (u32)$0080, (pointer)0, gW32AppIcon); // ICON_SMALL
        }
    }

class UXWin32Driver : Object<UXViewDriver>
    {
    void init(void)
        {
        }

    // ---- boot ----------------------------------------------------------------
    bool boot(i32* screenW, i32* screenH)
        {
        gW32Inst = GetModuleHandleA((pointer)0);
        gW32NextHandle = (i32)1;
        gW32ScrollerN = (i32)0;
        gW32Gfx = new UXGdiGraphics();
        WNDCLASSA wc;
        wc.style = (u32)CS_HREDRAW | (u32)CS_VREDRAW;
        wc._p0 = (u32)0;
        wc.lpfnWndProc = &UXWin32Proc;
        wc.cbClsExtra = (i32)0;
        wc.cbWndExtra = (i32)0;
        wc.hInstance = gW32Inst;
        wc.hIcon = (pointer)0;
        wc.hCursor = (pointer)0;
        gW32FaceBrush = CreateSolidBrush((u32)$00C0C0C0); // dialog face grey
        wc.hbrBackground = gW32FaceBrush;                 // the whole window is dialog-grey by default
        wc.lpszMenuName = (pointer)0;
        wc.lpszClassName = (pointer) "UXWin32";
        RegisterClassA((pointer)&wc);
        // The scroll-view child class (WS_VSCROLL container that paints an UXKit subtree).
        WNDCLASSA sc;
        sc.style = (u32)CS_HREDRAW | (u32)CS_VREDRAW;
        sc._p0 = (u32)0;
        sc.lpfnWndProc = &UXScroll32Proc;
        sc.cbClsExtra = (i32)0;
        sc.cbWndExtra = (i32)0;
        sc.hInstance = gW32Inst;
        sc.hIcon = (pointer)0;
        sc.hCursor = (pointer)0;
        sc.hbrBackground = gW32FaceBrush;
        sc.lpszMenuName = (pointer)0;
        sc.lpszClassName = (pointer) "UXScroll32";
        RegisterClassA((pointer)&sc);
        // The input-shield child class.  A NULL background brush is what makes it
        // transparent: with no brush the default erase paints nothing at all.
        WNDCLASSA hc;
        hc.style = (u32)0;
        hc._p0 = (u32)0;
        hc.lpfnWndProc = &UXShield32Proc;
        hc.cbClsExtra = (i32)0;
        hc.cbWndExtra = (i32)0;
        hc.hInstance = gW32Inst;
        hc.hIcon = (pointer)0;
        hc.hCursor = (pointer)0;
        hc.hbrBackground = (pointer)0;
        hc.lpszMenuName = (pointer)0;
        hc.lpszClassName = (pointer) "UXShield32";
        RegisterClassA((pointer)&hc);
        // The GL surface class.  CS_OWNDC is the point of it: the window gets a device
        // context of its own, which is what makes the pixel format chosen for it stick.
        WNDCLASSA gc;
        gc.style = (u32)CS_OWNDC;
        gc._p0 = (u32)0;
        gc.lpfnWndProc = &UXGl32Proc;
        gc.cbClsExtra = (i32)0;
        gc.cbWndExtra = (i32)0;
        gc.hInstance = gW32Inst;
        gc.hIcon = (pointer)0;
        gc.hCursor = (pointer)0;
        gc.hbrBackground = (pointer)0; // no brush: nothing is ever erased behind the swap
        gc.lpszMenuName = (pointer)0;
        gc.lpszClassName = (pointer) "UXGl32";
        RegisterClassA((pointer)&gc);
        gW32Font = GetStockObject((i32)DEFAULT_GUI_FONT); // the OS UI font, for every native control
        INITCOMMONCONTROLSEX icc;
        icc.dwSize = (u32)8;
        icc.dwICC = (u32)ICC_LISTVIEW_CLASSES | (u32)ICC_TREEVIEW_CLASSES | (u32)ICC_BAR_CLASSES | (u32)ICC_TAB_CLASSES | (u32)ICC_UPDOWN_CLASS | (u32)ICC_PROGRESS_CLASS;
        InitCommonControlsEx((pointer)&icc); // ListView/TreeView + trackbar/toolbar/tab/updown/progress
        screenW[0] = (i32)1024;
        screenH[0] = (i32)768; // GetSystemMetrics would be exact
        return true;
        }

    // ---- windows -------------------------------------------------------------
    // Whether every column of a table has an empty title: it shows no header row.
    bool untitled(UXTableView* tv)
        {
        for (i32 c = (i32)0; c < tv.numberOfColumns(); c = c + (i32)1)
            {
            u8* ti = tv.columnTitle(c);
            if (ti != (u8*)0 && ti[0] != (u8)0)
                {
                return false;
                }
            }
        return true;
        }
    // The smallest the window's content may be made by hand (WM_GETMINMAXINFO).
    void windowSetMinSize(i32 handle, i32 w, i32 h)
        {
        if (handle > (i32)0 && handle < (i32)64)
            {
            gW32MinW[handle] = w;
            gW32MinH[handle] = h;
            }
        }
    // The item of the native tree at `node` under window point (x, y): TVM_HITTEST, then its lParam.
    pointer outlineItemAt(i32 handle, i32 node, i32 x, i32 y)
        {
        if (handle <= (i32)0 || handle >= (i32)64 || gW32TreeOf[handle] == (pointer)0)
            {
            return (pointer)0;
            }
        W32Tree* t = (W32Tree*)gW32TreeOf[handle];
        if (node < (i32)0 || node >= t.count)
            {
            return (pointer)0;
            }
        pointer c = t.nodes[node].ctrl;
        if (c == (pointer)0 || self.effectiveHidden(gW32TreeOf[handle], node) != (i32)0)
            {
            return (pointer)0; // the toolkit's own say, not the OS's: a covered window is still there
            }
        POINT p;
        p.x = x;
        p.y = y;
        ClientToScreen(gW32Hwnds[handle], (pointer)&p);
        ScreenToClient(c, (pointer)&p);
        RECT r;
        GetClientRect(c, (pointer)&r);
        if (p.x < (i32)0 || p.y < (i32)0 || p.x >= r.right || p.y >= r.bottom)
            {
            return (pointer)0;
            }
        TVHITTESTINFO hi;
        hi.ptx = p.x;
        hi.pty = p.y;
        hi.flags = (u32)0;
        hi.hItem = (pointer)0;
        pointer it = SendMessageA(c, (u32)TVM_HITTEST, (pointer)0, (pointer)&hi);
        if (it == (pointer)0)
            {
            return (pointer)0;
            }
        TVITEM ti;
        w32TvitemInit(&ti);
        ti.mask = (u32)(TVIF_PARAM | TVIF_HANDLE);
        ti.hItem = it;
        SendMessageA(c, (u32)TVM_GETITEMA, (pointer)0, (pointer)&ti);
        return ti.lParam;
        }
    // A connection's line above the native controls: a click-through layered window over the
    // content, keyed on one colour so only the line shows.
    void windowLine(i32 handle, i32 on, i32 x0, i32 y0, i32 x1, i32 y1, i32 hx, i32 hy, i32 hw, i32 hh)
        {
        if (handle <= (i32)0 || handle >= (i32)64 || gW32Hwnds[handle] == (pointer)0)
            {
            return;
            }
        if (on == (i32)0)
            {
            if (gW32LineWin[handle] != (pointer)0)
                {
                ShowWindow(gW32LineWin[handle], (i32)SW_HIDE);
                }
            gW32LineOn[handle] = (i32)0;
            return;
            }
        i32 b = handle * (i32)8;
        gW32LineV[b] = x0;
        gW32LineV[b + (i32)1] = y0;
        gW32LineV[b + (i32)2] = x1;
        gW32LineV[b + (i32)3] = y1;
        gW32LineV[b + (i32)4] = hx;
        gW32LineV[b + (i32)5] = hy;
        gW32LineV[b + (i32)6] = hw;
        gW32LineV[b + (i32)7] = hh;
        pointer main = gW32Hwnds[handle];
        RECT rc;
        GetClientRect(main, (pointer)&rc);
        POINT o;
        o.x = (i32)0;
        o.y = (i32)0;
        ClientToScreen(main, (pointer)&o);
        if (gW32LineClass == (i32)0)
            {
            WNDCLASSA wc;
            wc.style = (u32)0;
            wc.cbClsExtra = (i32)0;
            wc.cbWndExtra = (i32)0;
            wc.hIcon = (pointer)0;
            wc.hCursor = (pointer)0;
            wc.hbrBackground = (pointer)0;
            wc.lpszMenuName = (pointer)0;
            wc.lpfnWndProc = (pointer)&UXLine32Proc;
            wc.hInstance = gW32Inst;
            wc.lpszClassName = (pointer) "UXLine32";
            RegisterClassA((pointer)&wc);
            gW32LineClass = (i32)1;
            }
        if (gW32LineWin[handle] == (pointer)0)
            {
            pointer lw = CreateWindowExA((u32)(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE),
                                         (pointer) "UXLine32", (pointer) "", (u32)WS_POPUP,
                                         o.x, o.y, rc.right, rc.bottom, main, (pointer)0, gW32Inst, (pointer)0);
            SetLayeredWindowAttributes(lw, (u32)$00FF00FF, (u8)255, (u32)LWA_COLORKEY);
            SetWindowLongPtrA(lw, (i32)GWLP_USERDATA, (pointer)handle);
            gW32LineWin[handle] = lw;
            }
        pointer w = gW32LineWin[handle];
        SetWindowPos(w, (pointer)0, o.x, o.y, rc.right, rc.bottom, (u32)(SWP_NOZORDER | SWP_NOACTIVATE));
        ShowWindow(w, (i32)SW_SHOWNOACTIVATE);
        gW32LineOn[handle] = (i32)1;
        InvalidateRect(w, (pointer)0, (i32)1);
        UpdateWindow(w);
        }
    // A context menu: TrackPopupMenu, which returns the pick (TPM_RETURNCMD) once the menu closes.
    i32 menuPopUp(i32 handle, pointer titles, pointer flags, i32 n, i32 x, i32 y)
        {
        u8** ts = (u8**)titles;
        i32* fs = (i32*)flags;
        if (gW32MenuTestPick != (i32)-2)
            {
            i32 at = (i32)0;
            for (i32 i = (i32)0; i < n && at < (i32)500; i = i + (i32)1)
                {
                if (i > (i32)0)
                    {
                    gW32MenuTestTitles[at] = (u8)'|';
                    at = at + (i32)1;
                    }
                u8* t = (fs[i] & (i32)1) != (i32)0 ? (u8*)"-" : ts[i];
                for (i32 j = (i32)0; t[j] != (u8)0 && at < (i32)500; j = j + (i32)1)
                    {
                    gW32MenuTestTitles[at] = t[j];
                    at = at + (i32)1;
                    }
                }
            gW32MenuTestTitles[at] = (u8)0;
            i32 pick = gW32MenuTestPick;
            gW32MenuTestPick = (i32)-2;
            return pick;
            }
        if (handle <= (i32)0 || handle >= (i32)64 || gW32Hwnds[handle] == (pointer)0 || n <= (i32)0)
            {
            return (i32)-1;
            }
        pointer m = CreatePopupMenu();
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            if ((fs[i] & (i32)1) != (i32)0)
                {
                AppendMenuA(m, (u32)MF_SEPARATOR, (pointer)0, (pointer)0);
                }
            else
                {
                u32 fl = (u32)MF_STRING | ((fs[i] & (i32)2) != (i32)0 ? (u32)MF_GRAYED : (u32)0);
                AppendMenuA(m, fl, (pointer)(i + (i32)1), (pointer)ts[i]);
                }
            }
        POINT p;
        p.x = x;
        p.y = y;
        ClientToScreen(gW32Hwnds[handle], (pointer)&p);
        i32 r = TrackPopupMenu(m, (u32)(TPM_RETURNCMD | TPM_NONOTIFY), p.x, p.y, (i32)0, gW32Hwnds[handle], (pointer)0);
        DestroyMenu(m);
        return r - (i32)1;
        }
    i32 windowCreate(i32 x, i32 y, i32 w, i32 h)
        {
        // The neutral w,h is the CONTENT size; grow it to the outer window size so the client area
        // (where the toolkit lays out) actually gets w x h.  No WS_*SCROLL — the toolkit's scrollable
        // views (the table) own their own scrolling; a window-level bar would be spurious.
        u32 style = (u32)WS_OVERLAPPEDWINDOW;
        RECT rc;
        rc.left = (i32)0;
        rc.top = (i32)0;
        rc.right = w;
        rc.bottom = h;
        AdjustWindowRect((pointer)&rc, style, gW32Menu != (pointer)0 ? (i32)1 : (i32)0);
        pointer hwnd = CreateWindowExA((u32)0, (pointer) "UXWin32", (pointer) "UXKit",
                                       style, x, y, rc.right - rc.left, rc.bottom - rc.top, (pointer)0, (pointer)0, gW32Inst, (pointer)0);
        i32 handle = (i32)0; // reuse a freed slot if there is one,
        // so create/destroy loops stay bounded
        for (i32 i = (i32)1; i < gW32NextHandle; i = i + (i32)1)
            {
            if (gW32Hwnds[i] == (pointer)0)
                {
                handle = i;
                break;
                }
            }
        if (handle == (i32)0)
            {
            handle = gW32NextHandle;
            gW32NextHandle = gW32NextHandle + (i32)1;
            }
        gW32Hwnds[handle] = hwnd;
        DragAcceptFiles(hwnd, (i32)1); // files dragged in from Explorer: WM_DROPFILES
        gW32MinW[handle] = (i32)0;
        gW32MinH[handle] = (i32)0;
        w32_app_icon_apply(hwnd); // an app icon set before this window opened
        gW32WinH[handle] = h;
        gW32ScrollY[handle] = (i32)0;
        gW32ScrollMax[handle] = (i32)0;
        gW32WinW[handle] = w;
        gW32ScrollX[handle] = (i32)0;
        gW32ScrollMaxX[handle] = (i32)0;
        gW32Native = gW32Native + (i32)1;
        // app menu is per-window on Win32
        if (gW32Menu != (pointer)0)
            {
            SetMenu(hwnd, gW32Menu);
            }
        return handle;
        }
    void windowSetContent(i32 handle, pointer fn, pointer ud)
        {
        gW32ContentFn = fn;
        SetWindowLongPtrA(gW32Hwnds[handle], (i32)GWLP_USERDATA, ud); // reverse map
        }
    void windowOpen(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        ShowWindow(gW32Hwnds[handle], (i32)SW_SHOW); // just map it; the caller's displayAll paints
        }
    void windowDestroy(i32 handle)
        {
        w32ScrollerDropWindow(handle); // BEFORE the destroy: its children die with it
        DestroyWindow(gW32Hwnds[handle]);
        gW32Hwnds[handle] = (pointer)0;
        // Only when the LAST window is gone do we break the GetMessage loop (WM_QUIT) so the app exits.
        // Closing a secondary window (the picker) leaves others open and must NOT quit.
        i32 live = (i32)0;
        for (i32 i = (i32)1; i < gW32NextHandle; i = i + (i32)1)
            {
            if (gW32Hwnds[i] != (pointer)0)
                {
                live = live + (i32)1;
                }
            }
        if (live == (i32)0)
            {
            PostQuitMessage((i32)0);
            }
        gW32Native = gW32Native - (i32)1;
        }
    // Windows has one title, so UXKit's title, subtitle and modified flag are COMPOSED into it the
    // way Windows applications do it: "*Notes - draft" -- a leading "*" for unsaved changes (as
    // Notepad shows "*Untitled"), and the subtitle after a dash.
    void windowSetTitle(i32 handle, u8* s)
        {
        if (handle <= (i32)0 || handle >= (i32)64)
            {
            return;
            }
        if (gW32Title[handle] != (u8*)0)
            {
            free((pointer)gW32Title[handle]);
            }
        gW32Title[handle] = UXStr.dup(s != (u8*)0 ? s : (u8*)"");
        self.composeTitle(handle);
        }
    void composeTitle(i32 handle)
        {
        u8* base = gW32Title[handle] != (u8*)0 ? gW32Title[handle] : (u8*)"";
        u8* t = gW32Modified[handle] ? UXStr.append((u8*)"*", base) : base;
        if (gW32Subtitle[handle] != (u8*)0 && gW32Subtitle[handle][(i32)0] != (u8)0)
            {
            t = UXStr.append(UXStr.append(t, (u8*)" - "), gW32Subtitle[handle]);
            }
        u16 wbuf[512]; // UTF-8 -> UTF-16 so a non-ASCII title isn't mangled
        i32 wch = MultiByteToWideChar((u32)CP_UTF8, (u32)0, (pointer)t, (i32)-1, (pointer)&wbuf[0], (i32)512);
        if (wch > (i32)0)
            {
            SetWindowTextW(gW32Hwnds[handle], (pointer)&wbuf[0]);
            }
        // fallback
        else
            {
            SetWindowTextA(gW32Hwnds[handle], (pointer)t);
            }
        }
    void windowSetSubtitle(i32 handle, u8* s)
        {
        if (handle <= (i32)0 || handle >= (i32)64)
            {
            return;
            }
        if (gW32Subtitle[handle] != (u8*)0)
            {
            free((pointer)gW32Subtitle[handle]);
            }
        gW32Subtitle[handle] = UXStr.dup(s != (u8*)0 ? s : (u8*)"");
        self.composeTitle(handle);
        }
    void windowSetInfo(i32 handle, u8* s)
        {
        }
    // One waveOut stream per sound; Windows mixes them.
    bool audioPlay(i16* pcm, i32 frames, i32 rate)
        {
        return w32_sound_play(pcm, frames, rate);
        }
    // The taskbar, Alt-Tab and title-bar icon of every window, now and opened later.
    bool appSetIcon(u8* data, i32 w, i32 h, i32 format)
        {
        pointer icon = w32_app_icon_make(data, w, h, format);
        if (icon == (pointer)0)
            {
            return false;
            }
        pointer old = gW32AppIcon;
        gW32AppIcon = icon;
        for (i32 k = (i32)1; k < (i32)64; k = k + (i32)1) // every slot of gW32Hwnds
            {
            w32_app_icon_apply(gW32Hwnds[k]);
            }
        if (old != (pointer)0)
            {
            pointer usr = LoadLibraryA((pointer)"user32.dll");
            W32DestroyIconFn* d = (W32DestroyIconFn*)GetProcAddress(usr, (u8*)"DestroyIcon");
            if (d != (W32DestroyIconFn*)0)
                {
                d(old); // no window holds it any more
                }
            }
        return true;
        }
    // The window's icon is its DOCUMENT's: given a file path, the file's own shell icon (what
    // Explorer shows for it), set big and small with WM_SETICON -- the counterpart of AppKit's proxy
    // icon.  Anything that is not a file (a theme slice name, "") goes back to the app's icon.
    void windowSetIcon(i32 handle, u8* slice)
        {
        if (handle <= (i32)0 || handle >= (i32)64 || gW32Hwnds[handle] == (pointer)0)
            {
            return;
            }
        pointer big = (pointer)0;
        pointer small = (pointer)0;
        if (slice != (u8*)0 && slice[(i32)0] != (u8)0)
            {
            u16 wpath[520];
            if (MultiByteToWideChar((u32)CP_UTF8, (u32)0, (pointer)slice, (i32)-1, (pointer)&wpath[0], (i32)520) > (i32)0)
                {
                SHFILEINFOW fi;
                if (w32SHGetFileInfoW((pointer)&wpath[0], (u32)0, (pointer)&fi, (u32)sizeof(SHFILEINFOW), (u32)(SHGFI_ICON | SHGFI_LARGEICON)) != (pointer)0)
                    {
                    big = fi.hIcon;
                    }
                if (w32SHGetFileInfoW((pointer)&wpath[0], (u32)0, (pointer)&fi, (u32)sizeof(SHFILEINFOW), (u32)(SHGFI_ICON | SHGFI_SMALLICON)) != (pointer)0)
                    {
                    small = fi.hIcon;
                    }
                }
            }
        // no document: the app's own icon (appSetIcon), or none
        if (big == (pointer)0)
            {
            big = gW32AppIcon;
            }
        if (small == (pointer)0)
            {
            small = gW32AppIcon;
            }
        pointer oldBig = SendMessageA(gW32Hwnds[handle], (u32)WM_SETICON, (pointer)ICON_BIG, big);
        pointer oldSmall = SendMessageA(gW32Hwnds[handle], (u32)WM_SETICON, (pointer)ICON_SMALL, small);
        // the document icons this window had before are its own to free -- never the app's icon,
        // which every window shares
        if (oldBig != (pointer)0 && oldBig != big && oldBig != gW32AppIcon)
            {
            w32DestroyIcon(oldBig);
            }
        if (oldSmall != (pointer)0 && oldSmall != small && oldSmall != gW32AppIcon && oldSmall != oldBig)
            {
            w32DestroyIcon(oldSmall);
            }
        }
    void windowSetModified(i32 handle, bool m)
        {
        if (handle <= (i32)0 || handle >= (i32)64)
            {
            return;
            }
        gW32Modified[handle] = m;
        self.composeTitle(handle);
        }
    // Report the content extent: set the scrollbar range to content-minus-visible.  The native
    // bar then owns the thumb/track; the neutral layoutFor subtracts windowScrollY, so the tree
    // and hit-testing scroll together (§11 — "hit-testing scrolls for free").
    void windowContentSize(i32 handle, i32 w, i32 h)
        {
        i32 visV = gW32WinH[handle] - (i32)40; // approx client height (frame/scrollbar)
        i32 maxV = h - visV;
        if (maxV < (i32)0)
            {
            maxV = (i32)0;
            }
        gW32ScrollMax[handle] = maxV;
        if (gW32ScrollY[handle] > maxV)
            {
            gW32ScrollY[handle] = maxV;
            }
        SetScrollRange(gW32Hwnds[handle], (i32)SB_VERT, (i32)0, maxV, (i32)1);
        SetScrollPos(gW32Hwnds[handle], (i32)SB_VERT, gW32ScrollY[handle], (i32)1);

        i32 visH = gW32WinW[handle] - (i32)24; // approx client width
        i32 maxH = w - visH;
        if (maxH < (i32)0)
            {
            maxH = (i32)0;
            }
        gW32ScrollMaxX[handle] = maxH;
        if (gW32ScrollX[handle] > maxH)
            {
            gW32ScrollX[handle] = maxH;
            }
        SetScrollRange(gW32Hwnds[handle], (i32)SB_HORZ, (i32)0, maxH, (i32)1);
        SetScrollPos(gW32Hwnds[handle], (i32)SB_HORZ, gW32ScrollX[handle], (i32)1);
        }
    i32 windowScrollX(i32 handle)
        {
        return gW32ScrollX[handle];
        }
    i32 windowScrollY(i32 handle)
        {
        return gW32ScrollY[handle];
        }
    void windowSetScroll(i32 handle, i32 x, i32 y)
        {
        if (y < (i32)0)
            {
            y = (i32)0;
            }
        if (y > gW32ScrollMax[handle])
            {
            y = gW32ScrollMax[handle];
            }
        if (x < (i32)0)
            {
            x = (i32)0;
            }
        if (x > gW32ScrollMaxX[handle])
            {
            x = gW32ScrollMaxX[handle];
            }
        gW32ScrollY[handle] = y;
        gW32ScrollX[handle] = x;
        SetScrollPos(gW32Hwnds[handle], (i32)SB_VERT, y, (i32)1);
        SetScrollPos(gW32Hwnds[handle], (i32)SB_HORZ, x, (i32)1);
        InvalidateRect(gW32Hwnds[handle], (pointer)0, (i32)1);
        UpdateWindow(gW32Hwnds[handle]);
        }
    // the client rect
    void windowContentGeometry(i32 handle, i32* w, i32* h)
        {
        RECT rc;
        rc.left = (i32)0;
        rc.top = (i32)0;
        rc.right = (i32)0;
        rc.bottom = (i32)0;
        GetClientRect(gW32Hwnds[handle], (pointer)&rc);
        w[0] = rc.right - rc.left;
        h[0] = rc.bottom - rc.top;
        }
    // Into a 32-bit top-down DIB section.  On Windows the driver renders the window's own content
    // itself (the content pass WM_PAINT runs, the GL frame included), which holds whether or not the
    // window is composited: the compositor's copy of a window on a desktop nobody is looking at may
    // never get the toolkit's paint.  The child controls come from that copy (PrintWindow, full
    // content), where they painted themselves; they will not paint into another DC.  Under Wine, the
    // window DC's pixels: Wine keeps a surface for each window, children included, even when covered.
    i32 windowSnapshot(i32 handle, i32 x, i32 y, i32 w, i32 h, u32* out)
        {
        pointer hwnd = handle > (i32)0 && handle < (i32)64 ? gW32Hwnds[handle] : (pointer)0;
        w32_snap_load();
        if (hwnd == (pointer)0 || gW32CreateDIBSection == (pointer)0 || gW32BitBlt == (pointer)0)
            {
            return (i32)0;
            }
        RECT crc;
        GetClientRect(hwnd, (pointer)&crc);
        i32 cw = crc.right;
        i32 ch = crc.bottom;
        if (cw <= (i32)0 || ch <= (i32)0 || x + w > cw || y + h > ch)
            {
            return (i32)0;
            }
        W32BmiHeader bmi;
        u8* z = (u8*)&bmi;
        for (i32 i = (i32)0; i < (i32)40; i = i + (i32)1)
            {
            z[i] = (u8)0;
            }
        bmi.biSize = (u32)40;
        bmi.biWidth = cw;
        bmi.biHeight = (i32)0 - ch; // top-down
        bmi.biPlanes = (u16)1;
        bmi.biBitCount = (u16)32;
        pointer bits = (pointer)0;
        W32CreateDIBSectionFn* mk = (W32CreateDIBSectionFn*)gW32CreateDIBSection;
        pointer dib = mk((pointer)0, (pointer)&bmi, (u32)0, &bits, (pointer)0, (u32)0);
        if (dib == (pointer)0 || bits == (pointer)0)
            {
            return (i32)0;
            }
        pointer mem = CreateCompatibleDC((pointer)0);
        pointer old = SelectObject(mem, dib);
        i32 ok = (i32)0;
        if (gW32UnderWine == (i32)0)
            {
            // the window's own paint into the bitmap -- the content pass WM_PAINT runs, the GL frame
            // blitted in it -- and then each child control printing itself over it
            RECT all;
            all.left = (i32)0;
            all.top = (i32)0;
            all.right = cw;
            all.bottom = ch;
            FillRect(mem, (pointer)&all, gW32FaceBrush); // the class background
            pointer ud = GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA);
            if (ud != (pointer)0 && gW32ContentFn != (pointer)0)
                {
                pointer was = gW32CurHdc;
                gW32CurHdc = mem;
                SelectObject(mem, gW32Font);
                UXContentFn* f = (UXContentFn*)gW32ContentFn;
                f((i32)0, (i32)0, (i32)0, cw, ch, ud);
                gW32CurHdc = was;
                }
            // the children as the compositor holds them, over the render (where it has a picture)
            pointer cbits = (pointer)0;
            pointer cdib = mk((pointer)0, (pointer)&bmi, (u32)0, &cbits, (pointer)0, (u32)0);
            if (cdib != (pointer)0 && cbits != (pointer)0 && gW32PrintWindow != (pointer)0)
                {
                pointer cmem = CreateCompatibleDC((pointer)0);
                pointer cold = SelectObject(cmem, cdib);
                W32PrintWindowFn* pw = (W32PrintWindowFn*)gW32PrintWindow;
                if (pw(hwnd, cmem, (u32)3) != (i32)0) // PW_CLIENTONLY | PW_RENDERFULLCONTENT
                    {
                    w32SnapChildren(hwnd, (u32*)cbits, (u32*)bits, cw, ch);
                    }
                SelectObject(cmem, cold);
                DeleteDC(cmem);
                }
            if (cdib != (pointer)0)
                {
                DeleteObject(cdib);
                }
            ok = (i32)1;
            }
        else
            {
            pointer wdc = GetDC(hwnd);
            W32BitBltFn* bb = (W32BitBltFn*)gW32BitBlt;
            ok = bb(mem, (i32)0, (i32)0, cw, ch, wdc, (i32)0, (i32)0, (u32)$00CC0020); // SRCCOPY
            ReleaseDC(hwnd, wdc);
            }
        u32* px = (u32*)bits;
        for (i32 j = (i32)0; j < h; j = j + (i32)1)
            {
            for (i32 i = (i32)0; i < w; i = i + (i32)1)
                {
                out[j * w + i] = (u32)$FF000000 | (px[(y + j) * cw + x + i] & (u32)$00FFFFFF);
                }
            }
        SelectObject(mem, old);
        DeleteDC(mem);
        DeleteObject(dib);
        return ok != (i32)0 ? (i32)1 : (i32)0;
        }
    void windowInvalidate(i32 handle)
        {
        InvalidateRect(gW32Hwnds[handle], (pointer)0, (i32)1);
        w32ScrollersInvalidate(handle); // the scroll containers are separate HWNDs — see the table
        UpdateWindow(gW32Hwnds[handle]);
        }
    void windowOrderFront(i32 handle)
        {
        BringWindowToTop(gW32Hwnds[handle]);
        SetForegroundWindow(gW32Hwnds[handle]);
        }
    // The common file dialogs, GetOpenFileName and GetSaveFileName.  (They were once thought to hang
    // under Wine; as with ChooseColor, what hung was a test with nothing to answer the modal dialog.)
    bool hasNativeFileOpen(void)
        {
        return true;
        }
    // no platform navigation stack here: UXNavigationController draws its own bar
    bool hasNativeNavigation(void)
        {
        return false;
        }
    pointer navAttach(i32 win, i32 navId, i32 x, i32 y, i32 w, i32 h)
        {
        return (pointer)0;
        }
    void navPush(pointer nav, u8* title, i32 animated)
        {
        }
    void navPop(pointer nav, i32 animated)
        {
        }
    bool hasNativeFileSave(void)
        {
        return true;
        }
    i32 fileSave(u8* prompt, u8* startDir, u8* defaultName, u8* out, i32 outCap)
        {
        return self.w32FileDialog(true, prompt, startDir, defaultName, out, outCap);
        }
    // The common colour dialog, ChooseColor, opened full (the custom-colour half with its R/G/B
    // fields) and seeded with the current colour.  (It was once thought to hang under Wine; what
    // hung was a test with nothing to answer the modal dialog.  A gate answers it through the hook.)
    bool hasNativeColorPicker(void)
        {
        return true;
        }
    i32 pickColor(i32 r, i32 g, i32 b, i32* outR, i32* outG, i32* outB)
        {
        u32 cust[16];
        for (i32 i = (i32)0; i < (i32)16; i = i + (i32)1)
            {
            cust[i] = (u32)$FFFFFF;
            }
        CHOOSECOLORA cc;
        u8* z = (u8*)&cc;
        for (i32 i = (i32)0; i < (i32)72; i = i + (i32)1)
            {
            z[i] = (u8)0;
            }
        cc.lStructSize = (u32)72;
        cc.hwndOwner = gW32Hwnds[(i32)1];
        cc.rgbResult = ((u32)b << 16) | ((u32)g << 8) | (u32)r; // a COLORREF is 0x00BBGGRR
        cc.lpCustColors = (pointer)&cust[0];
        cc.Flags = (u32)CC_RGBINIT | (u32)CC_FULLOPEN;
        if (gW32TestDialogHook != (pointer)0)
            {
            cc.Flags = cc.Flags | (u32)CC_ENABLEHOOK;
            cc.lpfnHook = gW32TestDialogHook;
            }
        if (ChooseColorA((pointer)&cc) == (i32)0)
            {
            return (i32)0;
            }
        outR[0] = (i32)(cc.rgbResult & (u32)$FF);
        outG[0] = (i32)((cc.rgbResult >> 8) & (u32)$FF);
        outB[0] = (i32)((cc.rgbResult >> 16) & (u32)$FF);
        return (i32)1;
        }
    // The common font dialog, ChooseFont, seeded with the family, size (points), weight and slant.
    bool hasNativeFontPicker(void)
        {
        return true;
        }
    i32 pickFont(u8* inF, i32 inS, i32 inB, i32 inI, u8* outF, i32 cap, i32* outS, i32* outB, i32* outI)
        {
        LOGFONTA lf;
        u8* z = (u8*)&lf;
        for (i32 i = (i32)0; i < (i32)60; i = i + (i32)1)
            {
            z[i] = (u8)0;
            }
        lf.lfHeight = (i32)0 - (inS * (i32)96 + (i32)36) / (i32)72; // points -> pixels at 96 dpi
        lf.lfWeight = inB != (i32)0 ? (i32)700 : (i32)400;
        lf.lfItalic = inI != (i32)0 ? (u8)1 : (u8)0;
        i32 k = (i32)0;
        while (inF != (u8*)0 && inF[k] != (u8)0 && k < (i32)31)
            {
            lf.lfFaceName[k] = inF[k];
            k = k + (i32)1;
            }
        lf.lfFaceName[k] = (u8)0;
        CHOOSEFONTA cf;
        u8* y = (u8*)&cf;
        for (i32 i = (i32)0; i < (i32)104; i = i + (i32)1)
            {
            y[i] = (u8)0;
            }
        cf.lStructSize = (u32)104;
        cf.hwndOwner = gW32Hwnds[(i32)1];
        cf.lpLogFont = (pointer)&lf;
        cf.iPointSize = inS * (i32)10;
        cf.Flags = (u32)CF_SCREENFONTS | (u32)CF_INITTOLOGFONTSTRUCT | (u32)CF_NOVERTFONTS;
        if (gW32TestDialogHook != (pointer)0)
            {
            cf.Flags = cf.Flags | (u32)CF_ENABLEHOOK;
            cf.lpfnHook = gW32TestDialogHook;
            }
        if (ChooseFontA((pointer)&cf) == (i32)0)
            {
            return (i32)0;
            }
        i32 n = (i32)0;
        while (lf.lfFaceName[n] != (u8)0 && n < cap - (i32)1 && n < (i32)31)
            {
            outF[n] = lf.lfFaceName[n];
            n = n + (i32)1;
            }
        outF[n] = (u8)0;
        outS[0] = (cf.iPointSize + (i32)5) / (i32)10; // tenths of a point -> points
        outB[0] = lf.lfWeight >= (i32)600 ? (i32)1 : (i32)0;
        outI[0] = lf.lfItalic != (u8)0 ? (i32)1 : (i32)0;
        return (i32)1;
        }
    // Measure in a DC of our own, not gW32CurHdc: line breaking happens during layout, outside any
    // WM_PAINT, when that handle is stale.  One screen-compatible DC, made on first use and kept.
    i32 nowMs(void)
        {
        return (i32)GetTickCount();
        }
    // The fine clock is the coarse one in microseconds: this backend's clock has no more
    // resolution than a millisecond, and inventing bits that are not there would make a
    // frame-time measurement look precise on a backend where it is not.
    i32 nowUs(void)
        {
        return (i32)GetTickCount() * (i32)1000;
        }
    // The offset as the DIFFERENCE between local and UTC civil time, rather than
    // GetTimeZoneInformation's bias-plus-daylight-bias arithmetic: fewer ways to get the sign wrong,
    // and DST is already in whatever GetLocalTime returns.  Rounded to the minute; the date rollover
    // is handled by comparing day numbers, not by assuming the two are the same day.
    i32 localOffsetMinutes(void)
        {
        SYSTEMTIME u;
        SYSTEMTIME l;
        GetSystemTime((pointer)&u);
        GetLocalTime((pointer)&l);
        i32 du = UXDate.make((i32)u.year, (i32)u.month, (i32)u.day).dayNumber();
        i32 dl = UXDate.make((i32)l.year, (i32)l.month, (i32)l.day).dayNumber();
        i32 mu = (i32)u.hour * (i32)60 + (i32)u.minute;
        i32 ml = (i32)l.hour * (i32)60 + (i32)l.minute;
        return (dl - du) * (i32)1440 + (ml - mu);
        }

    // Settings, in an .ini under %APPDATA%\UXKit.  The profile API is already a (section, key) -> string
    // store, and it does the read-modify-write of one key inside an existing file — which is the only
    // hard part of a settings file — so there is no format of ours to get wrong.  Section = domain.
    u8* settingSection(u8* domain)
        {
        if (domain == (u8*)0 || domain[(i32)0] == (u8)0)
            {
            return (u8*)"Shared";
            }
        return domain;
        }
    bool settingGet(u8* domain, u8* key, u8* out, i32 cap)
        {
        if (out == (u8*)0 || cap <= (i32)0)
            {
            return false;
            }
        // A SENTINEL default, not "": an empty string is a legal stored value, and the API cannot
        // otherwise tell "the key holds nothing" from "there is no key".
        GetPrivateProfileStringA((pointer)self.settingSection(domain), (pointer)key,
                                 (pointer)w32NoValue(), (pointer)out, cap, (pointer)w32SettingsFile());
        if (out[(i32)0] == (u8)1 && out[(i32)1] == (u8)0)
            {
            out[(i32)0] = (u8)0;
            return false;
            }
        return true;
        }
    bool settingSet(u8* domain, u8* key, u8* value)
        {
        return WritePrivateProfileStringA((pointer)self.settingSection(domain), (pointer)key,
                                          (pointer)value, (pointer)w32SettingsFile()) != (i32)0;
        }
    bool settingRemove(u8* domain, u8* key)
        {
        // A null value is the profile API's delete.
        return WritePrivateProfileStringA((pointer)self.settingSection(domain), (pointer)key,
                                          (pointer)0, (pointer)w32SettingsFile()) != (i32)0;
        }

    // SYSTEMTIME is already UTC civil components; its resolution stops at milliseconds.
    void nowUTC(i32* out7)
        {
        SYSTEMTIME st;
        GetSystemTime((pointer)&st);
        out7[(i32)0] = (i32)st.year;
        out7[(i32)1] = (i32)st.month;
        out7[(i32)2] = (i32)st.day;
        out7[(i32)3] = (i32)st.hour;
        out7[(i32)4] = (i32)st.minute;
        out7[(i32)5] = (i32)st.second;
        out7[(i32)6] = (i32)st.millis * (i32)1000;
        }
    i32 textWidth(u8* s, i32 size)
        {
        if (gW32MeasureDC == (pointer)0)
            {
            gW32MeasureDC = CreateCompatibleDC((pointer)0);
            }
        if (gW32MeasureDC == (pointer)0)
            {
            return (i32)0;
            }
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        pointer fnt = gW32Font;
        if (size > (i32)0)
            {
            fnt = CreateFontA((i32)0 - size, (i32)0, (i32)0, (i32)0, (i32)400,
                              (u32)0, (u32)0, (u32)0, (u32)1, (u32)0, (u32)0, (u32)0, (u32)0, (u8*)"");
            }
        pointer old = SelectObject(gW32MeasureDC, fnt);
        SIZE sz;
        sz.cx = (i32)0;
        sz.cy = (i32)0;
        GetTextExtentPoint32A(gW32MeasureDC, (pointer)s, n, (pointer)&sz);
        SelectObject(gW32MeasureDC, old);
        if (size > (i32)0)
            {
            DeleteObject(fnt);
            }
        return sz.cx;
        }

    i32 textWidthStyled(u8* s, u8* family, i32 size, bool bold, bool italic)
        {
        return self.textWidthWeight(s, family, size,
                                    bold ? (i32)UXWEIGHT_SEMIBOLD : (i32)UXWEIGHT_NORMAL, italic);
        }
    // GDI's CreateFontA takes the 0..1000 weight directly, so the measure and the drawing call build
    // the SAME face from the same number (see UXGdiGraphics.drawTextFontRGBA).
    i32 textWidthWeight(u8* s, u8* family, i32 size, i32 weight, bool italic)
        {
        if (gW32MeasureDC == (pointer)0)
            {
            gW32MeasureDC = CreateCompatibleDC((pointer)0);
            }
        if (gW32MeasureDC == (pointer)0)
            {
            return (i32)0;
            }
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        i32 h = (i32)0 - (size > (i32)0 ? size : (i32)12);
        i32 w = weight > (i32)0 ? weight : (i32)400;
        pointer fnt = CreateFontA(h, (i32)0, (i32)0, (i32)0, w,
                                  italic ? (u32)1 : (u32)0, (u32)0, (u32)0, (u32)1, (u32)0, (u32)0, (u32)0, (u32)0, family);
        pointer old = SelectObject(gW32MeasureDC, fnt);
        SIZE sz;
        sz.cx = (i32)0;
        sz.cy = (i32)0;
        GetTextExtentPoint32A(gW32MeasureDC, (pointer)s, n, (pointer)&sz);
        SelectObject(gW32MeasureDC, old);
        DeleteObject(fnt);
        return sz.cx;
        }
    // TextOutA puts y at the TOP of the cell, so the baseline is tmAscent below it.
    i32 textAscent(u8* family, i32 size, i32 weight, bool italic)
        {
        if (gW32MeasureDC == (pointer)0)
            {
            gW32MeasureDC = CreateCompatibleDC((pointer)0);
            }
        if (gW32MeasureDC == (pointer)0)
            {
            return (size > (i32)0 ? size : (i32)12);
            }
        i32 h = (i32)0 - (size > (i32)0 ? size : (i32)12);
        i32 w = weight > (i32)0 ? weight : (i32)400;
        pointer fnt = CreateFontA(h, (i32)0, (i32)0, (i32)0, w,
                                  italic ? (u32)1 : (u32)0, (u32)0, (u32)0, (u32)1, (u32)0, (u32)0, (u32)0, (u32)0, family);
        pointer old = SelectObject(gW32MeasureDC, fnt);
        TEXTMETRICA tm;
        tm.tmHeight = (i32)0;
        tm.tmAscent = (i32)0;
        tm.tmDescent = (i32)0;
        tm.tmInternalLeading = (i32)0;
        GetTextMetricsA(gW32MeasureDC, (pointer)&tm);
        SelectObject(gW32MeasureDC, old);
        DeleteObject(fnt);
        return tm.tmAscent > (i32)0 ? tm.tmAscent : (size > (i32)0 ? size : (i32)12);
        }

    // The native COMBOBOX drops its own list and reports CBN_SELCHANGE — nothing to run here.
    i32 runPopupMenu(pointer peer, i32 x, i32 y)
        {
        return (i32)-1;
        }
    // A curated list of common Windows faces for the toolkit chooser; drawTextFont hands the name to
    // CreateFontA, which substitutes a close face when the exact one is not installed (e.g. under Wine).
    u8* w32Family(i32 i)
        {
        if (i == (i32)0)
            {
            return (u8*)"Arial";
            }
        if (i == (i32)1)
            {
            return (u8*)"Times New Roman";
            }
        if (i == (i32)2)
            {
            return (u8*)"Courier New";
            }
        if (i == (i32)3)
            {
            return (u8*)"Verdana";
            }
        if (i == (i32)4)
            {
            return (u8*)"Georgia";
            }
        if (i == (i32)5)
            {
            return (u8*)"Tahoma";
            }
        if (i == (i32)6)
            {
            return (u8*)"Trebuchet MS";
            }
        if (i == (i32)7)
            {
            return (u8*)"Comic Sans MS";
            }
        if (i == (i32)8)
            {
            return (u8*)"Impact";
            }
        if (i == (i32)9)
            {
            return (u8*)"Consolas";
            }
        if (i == (i32)10)
            {
            return (u8*)"Palatino Linotype";
            }
        return (u8*)"Segoe UI";
        }
    i32 fontFamilyCount(void)
        {
        return (i32)12;
        }
    i32 fontFamilyName(i32 idx, u8* out, i32 cap)
        {
        if (idx < (i32)0 || idx >= (i32)12)
            {
            return (i32)-1;
            }
        u8* nm = self.w32Family(idx);
        i32 i = (i32)0;
        while (nm[i] != (u8)0 && i < cap - (i32)1)
            {
            out[i] = nm[i];
            i = i + (i32)1;
            }
        out[i] = (u8)0;
        return i;
        }
    i32 fileOpen(u8* prompt, u8* startDir, u8* out, i32 outCap)
        {
        return self.w32FileDialog(false, prompt, startDir, (u8*)0, out, outCap);
        }
    // Both file dialogs.  save asks about replacing an existing file itself (OFN_OVERWRITEPROMPT), and
    // starts with defaultName in the name box.  The chosen path is written into out.
    i32 w32FileDialog(bool save, u8* prompt, u8* startDir, u8* defaultName, u8* out, i32 outCap)
        {
        // A non-NULL, double-NUL-terminated filter ("All Files" / *.*): a NULL filter faults some
        // comdlg32 builds, and the modern dialog needs the thread in a COM apartment.
        u8 filt[16];
        filt[(i32)0] = (u8)'A';
        filt[(i32)1] = (u8)'l';
        filt[(i32)2] = (u8)'l';
        filt[(i32)3] = (u8)0;
        filt[(i32)4] = (u8)'*';
        filt[(i32)5] = (u8)'.';
        filt[(i32)6] = (u8)'*';
        filt[(i32)7] = (u8)0;
        filt[(i32)8] = (u8)0;
        OPENFILENAMEA ofn;
        u8* z = (u8*)&ofn;
        // zero the struct
        for (i32 i = (i32)0; i < (i32)152; i = i + (i32)1)
            {
            z[i] = (u8)0;
            }
        i32 n = (i32)0;
        while (save && defaultName != (u8*)0 && defaultName[n] != (u8)0 && n < outCap - (i32)1)
            {
            out[n] = defaultName[n];
            n = n + (i32)1;
            }
        out[n] = (u8)0;
        ofn.lStructSize = (u32)152;
        ofn.hwndOwner = gW32Hwnds[(i32)1];
        ofn.lpstrFilter = (u8*)&filt[0];
        ofn.lpstrFile = out;
        ofn.nMaxFile = (u32)outCap;
        ofn.lpstrInitialDir = startDir;
        ofn.lpstrTitle = prompt;
        ofn.Flags = (u32)OFN_PATHMUSTEXIST | (u32)OFN_HIDEREADONLY | (u32)OFN_NOCHANGEDIR | (u32)OFN_EXPLORER;
        ofn.Flags = ofn.Flags | (save ? (u32)OFN_OVERWRITEPROMPT : (u32)OFN_FILEMUSTEXIST);
        if (gW32TestDialogHook != (pointer)0)
            {
            ofn.Flags = ofn.Flags | (u32)OFN_ENABLEHOOK;
            ofn.lpfnHook = gW32TestDialogHook;
            }
        OleInitialize((pointer)0);
        i32 ok = save ? GetSaveFileNameA((pointer)&ofn) : GetOpenFileNameA((pointer)&ofn);
        OleUninitialize();
        if (ok == (i32)0)
            {
            out[0] = (u8)0;
            return (i32)0;
            }
        return (i32)1;
        }
    i32 listDir(u8* path, u8* out, i32 outCap)
        {
        u8 pat[600];
        i32 n = (i32)0; // pattern = path + "\*"
        while (path[n] != (u8)0 && n < (i32)590)
            {
            pat[n] = path[n];
            n = n + (i32)1;
            }
        pat[n] = (u8)92;
        pat[n + (i32)1] = (u8)42;
        pat[n + (i32)2] = (u8)0; // '\' '*'
        WIN32_FIND_DATAA wfd;
        pointer h = FindFirstFileA((pointer)&pat[0], (pointer)&wfd);
        if (h == (pointer)INVALID_HANDLE_VALUE)
            {
            out[0] = (u8)0;
            return (i32)-1;
            }
        i32 off = (i32)0;
        i32 cnt = (i32)0;
        i32 more = (i32)1;
        while (more != (i32)0)
            {
            u8* nm = (u8*)&wfd.cFileName[0];
            i32 skip = (nm[0] == (u8)46 && (nm[1] == (u8)0 || (nm[1] == (u8)46 && nm[2] == (u8)0))) ? (i32)1 : (i32)0;
            if (skip == (i32)0 && off < outCap - (i32)300)
                {
                bool isdir = (wfd.dwFileAttributes & (u32)FILE_ATTRIBUTE_DIRECTORY) != (u32)0;
                out[off] = isdir ? (u8)100 : (u8)102; // 'd'/'f'
                off = off + (i32)1;
                out[off] = (u8)9;
                off = off + (i32)1; // '\t'
                // size (bytes, low dword — plenty for a file panel), then a tab
                u32 v = isdir ? (u32)0 : wfd.nFileSizeLow;
                if (v == (u32)0)
                    {
                    out[off] = (u8)48;
                    off = off + (i32)1;
                    }
                else
                    {
                    u8 tmp[12];
                    i32 tl = (i32)0;
                    while (v > (u32)0)
                        {
                        tmp[tl] = (u8)((u32)48 + (v % (u32)10));
                        tl = tl + (i32)1;
                        v = v / (u32)10;
                        }
                    while (tl > (i32)0)
                        {
                        tl = tl - (i32)1;
                        out[off] = tmp[tl];
                        off = off + (i32)1;
                        }
                    }
                out[off] = (u8)9;
                off = off + (i32)1; // '\t'
                i32 k = (i32)0;
                while (nm[k] != (u8)0)
                    {
                    out[off] = nm[k];
                    off = off + (i32)1;
                    k = k + (i32)1;
                    }
                out[off] = (u8)10;
                off = off + (i32)1; // '\n'
                cnt = cnt + (i32)1;
                }
            more = FindNextFileA(h, (pointer)&wfd);
            }
        FindClose(h);
        out[off] = (u8)0;
        return cnt;
        }
    i32 fileDelete(u8* path)
        {
        return DeleteFileA((pointer)path) != (i32)0 ? (i32)1 : (i32)0;
        }
    i32 fileRename(u8* src, u8* dst)
        {
        return MoveFileA((pointer)src, (pointer)dst) != (i32)0 ? (i32)1 : (i32)0;
        }
    i32 fileCopy(u8* src, u8* dst)
        {
        return CopyFileA((pointer)src, (pointer)dst, (i32)0) != (i32)0 ? (i32)1 : (i32)0;
        }
    // Honour the damage rect: UXWindow.display() clips the repaint to it (UXWindow.xc — a node outside
    // the damage is skipped), so we must invalidate ONLY that rect.  Invalidating the whole client with
    // erase=TRUE would clear every pixel and then repaint just the damaged nodes, wiping anything else out
    // (e.g. a slider drag marks only slider+progress dirty -> the collection view below vanished).
    void windowInvalidateRect(i32 handle, i32 x, i32 y, i32 w, i32 h)
        {
        RECT rc;
        rc.left = x;
        rc.top = y;
        rc.right = x + w;
        rc.bottom = y + h;
        InvalidateRect(gW32Hwnds[handle], (pointer)&rc, (i32)1);
        w32ScrollersInvalidate(handle); // the damage rect can't address a scrolled child — see above
        UpdateWindow(gW32Hwnds[handle]);
        }
    // Which of OUR windows is at a screen point.  This answered "1" from the days when the driver
    // opened one window; the kitchen sink has had several (Windows menu) for a while, and anything
    // reaching UXApplication.windowAt would have been told the wrong one.  Clicks do not go through
    // here — the driver tags ev.handle, which the run loop prefers — so it stayed wrong quietly.
    // Walk the table topmost-first: later handles are the more recently opened windows.
    i32 windowAtPoint(i32 x, i32 y)
        {
        RECT r;
        for (i32 i = gW32NextHandle - (i32)1; i >= (i32)1; i = i - (i32)1)
            {
            pointer hw = gW32Hwnds[i];
            if (hw == (pointer)0)
                {
                continue;
                }
            if (GetWindowRect(hw, (pointer)&r) == (i32)0)
                {
                continue;
                }
            if (x >= r.left && x < r.right && y >= r.top && y < r.bottom)
                {
                return i;
                }
            }
        return (i32)0; // no window of ours there
        }
    // A toolkit-drawn drag (a split divider): poll the real-time button + cursor (native controls do
    // their own drag).  While the left button is held, return the cursor in window-local coords; the
    // caller repaints via windowInvalidate, which UpdateWindows a synchronous WM_PAINT, so it's live.
    // a view may loop on trackDragStep inside its mouseDown
    bool dragTrackingIsModal(void)
        {
        return true;
        }
    i32 trackDragStep(i32* x, i32* y)
        {
        // see gInputReplay (UXEvent.xc)
        if (gInputReplay)
            {
            return (i32)0;
            }
        // released
        if ((GetAsyncKeyState((i32)VK_LBUTTON) & (i32)$8000) == (i32)0)
            {
            return (i32)0;
            }
        POINT p;
        GetCursorPos((pointer)&p);
        ScreenToClient(GetActiveWindow(), (pointer)&p); // screen -> window-local (matches mouseDown)
        x[0] = p.x + gUXDragDX; // in the press's terms: a drag that began on a scrolled document
        y[0] = p.y + gUXDragDY;
        Sleep((u32)8); // ~120 Hz, don't spin the CPU
        return (i32)1;
        }

    // ---- the shadow tree -----------------------------------------------------
    pointer structNew(void)
        {
        W32Tree* t = (W32Tree*)malloc((u32)sizeof(W32Tree));
        t.cap = (i32)16;
        t.count = (i32)0;
        t.nodes = (W32Node*)calloc((u32)t.cap, (u32)sizeof(W32Node));
        return (pointer)t;
        }
    void structFree(pointer h)
        {
        if (h == (pointer)0)
            {
            return;
            }
        W32Tree* t = (W32Tree*)h;
        if (t.nodes != (W32Node*)0)
            {
            free((pointer)t.nodes);
            }
        free(h);
        }
    // no .rsc on Win32
    void structAdopt(pointer h, pointer t, i32 n)
        {
        }
    // The "raw structure" the draw seam passes to treeDraw/treeHitTest.  On GEM that is the
    // OBJECT[] array; here it is the tree itself, so those ops reach .nodes.  Opaque either way.
    pointer structObjects(pointer h)
        {
        return h;
        }
    i32 structLength(pointer h)
        {
        return ((W32Tree*)h).count;
        }

    void structGrow(pointer h, i32 want)
        {
        W32Tree* t = (W32Tree*)h;
        if (want <= t.cap)
            {
            return;
            }
        i32 cap = t.cap;
        while (cap < want)
            {
            cap = cap * (i32)2;
            }
        t.nodes = (W32Node*)realloc((pointer)t.nodes, (u32)cap * (u32)sizeof(W32Node));
        t.cap = cap;
        }
    i32 structAppend(pointer h, i32 kind, i32 x, i32 y, i32 w, i32 ht)
        {
        W32Tree* t = (W32Tree*)h;
        self.structGrow(h, t.count + (i32)1);
        i32 i = t.count;
        W32Node* n = &t.nodes[i];
        n.kind = kind;
        n.x = (i16)x;
        n.y = (i16)y;
        n.w = (i16)w;
        n.h = (i16)ht;
        n.hidden = (i16)0;
        n.selected = (i16)0;
        n.enabled = (i16)1;
        n.clips = (i16)0;
        n.clipR = (i16)0;
        n.clipIn = (i16)0;
        n.selectable = (i16)0;
        n.editable = (i16)0;
        n.spec = (pointer)0;
        n.next = (i16)-1;
        n.head = (i16)-1;
        n.tail = (i16)-1;
        n.parent = (i16)-1;
        // EVERY field, explicitly: the first 16 nodes ride the calloc, but a
        // grown tree's tail is raw realloc memory — a garbage non-null ctrl
        // here made realizeTree MoveWindow a bogus handle instead of creating
        // the control, and node 17+ of any window lost its native widgets.
        n.ctrl = (pointer)0;
        n.peer = (pointer)0;
        t.count = i + (i32)1;
        return i;
        }
    void structAddChild(pointer h, i32 parent, i32 child)
        {
        W32Node* t = ((W32Tree*)h).nodes;
        t[child].parent = (i16)parent;
        t[child].next = (i16)-1;
        if (t[parent].head == (i16)-1)
            {
            t[parent].head = (i16)child;
            }
        else
            {
            t[t[parent].tail].next = (i16)child;
            }
        t[parent].tail = (i16)child;
        }
    void structRemoveChild(pointer h, i32 parent, i32 child)
        {
        W32Node* t = ((W32Tree*)h).nodes;
        i16 c = t[parent].head;
        if (c == (i16)child)
            {
            t[parent].head = t[child].next;
            }
        else
            {
            while (c != (i16)-1 && t[c].next != (i16)child)
                {
                c = t[c].next;
                }
            if (c != (i16)-1)
                {
                t[c].next = t[child].next;
                }
            }
        if (t[parent].tail == (i16)child)
            {
            t[parent].tail = c;
            }
        t[child].next = (i16)-1;
        t[child].parent = (i16)-1;
        self.pushHiddenSubtree(h, child); // it is off the tree; take it off screen
        }
    // no OF_LASTOB needed
    void structFinalise(pointer h)
        {
        }

    // Move the native child NOW — see the note on the AppKit driver's copy.
    // Win32 shared the same gap: shadow-only, with the real move deferred to a
    // realizeTree that setFrame does not trigger.
    void structSetFrame(pointer h, i32 i, i32 x, i32 y, i32 w, i32 ht)
        {
        W32Tree* t = (W32Tree*)h;
        W32Node* n = &t.nodes[i];
        n.x = (i16)x;
        n.y = (i16)y;
        n.w = (i16)w;
        n.h = (i16)ht;
        if (n.ctrl != (pointer)0)
            {
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 aw = (i32)0;
            i32 ah = (i32)0;
            self.structAbsFrame(h, i, &ax, &ay, &aw, &ah);
            MoveWindow(n.ctrl, ax, ay, aw, ah, (i32)1);
            if ((i32)n.kind == (i32)UXKindGLView)
                {
                w32_gl_viewport(n.peer); // the drawable moved: the viewport is the driver's
                }
            }
        }
    // Drive the UXScroll32 child: SetScrollPos clamps to the range the container already set from
    // the content height, so an out-of-range request lands at the nearest legal offset rather than
    // scrolling into blank space.  Repaint, because the child draws the subtree at -pos itself.
    // A TABLE's internal scroll view gets no UXScroll32 of its own — the native ListView scrolls
    // itself — so the container for such a node is the enclosing list, found by walking up.  Returns
    // 0 when neither exists.  `isList` says which of the two it is: they are driven differently.
    pointer scrollContainer(pointer h, i32 node, i32* isList)
        {
        W32Tree* t = (W32Tree*)h;
        isList[(i32)0] = (i32)0;
        if (t.nodes[node].ctrl != (pointer)0)
            {
            return t.nodes[node].ctrl;
            }
        i32 p = (i32)t.nodes[node].parent;
        while (p >= (i32)0)
            {
            if (t.nodes[p].ctrl != (pointer)0 && (i32)t.nodes[p].kind == (i32)UXKindTable)
                {
                isList[(i32)0] = (i32)1;
                return t.nodes[p].ctrl;
                }
            p = (i32)t.nodes[p].parent;
            }
        return (pointer)0;
        }
    // The height of one row in a report-mode list, from the control rather than from the toolkit's
    // idea of it — LVM_SCROLL counts in rows here, so the conversion has to match what is on screen.
    i32 listRowHeight(pointer lv)
        {
        RECT r;
        r.left = (i32)0;
        r.top = (i32)0;
        r.right = (i32)0;
        r.bottom = (i32)0;
        if (SendMessageA(lv, (u32)LVM_GETITEMRECT, (pointer)0, (pointer)&r) == (pointer)0)
            {
            return (i32)0;
            }
        i32 hh = r.bottom - r.top;
        return hh > (i32)0 ? hh : (i32)0;
        }
    void nativeScrollTo(pointer h, i32 node, i32 px)
        {
        i32 isList = (i32)0;
        pointer c = self.scrollContainer(h, node, &isList);
        if (c == (pointer)0)
            {
            return;
            }
        if (isList != (i32)0)
            {
            // LVM_SCROLL is a DELTA in PIXELS — rounded to whole lines in report view, which is the
            // one detail worth getting right: passing the delta in ROWS scrolls by a couple of pixels
            // and rounds to nothing, so a seek arrives a row short and never quite returns to 0.
            i32 rh = self.listRowHeight(c);
            if (rh <= (i32)0)
                {
                return;
                }
            i32 want = px / rh;
            i32 top = (i32)SendMessageA(c, (u32)LVM_GETTOPINDEX, (pointer)0, (pointer)0);
            if (want == top)
                {
                return;
                }
            SendMessageA(c, (u32)LVM_SCROLL, (pointer)0, (pointer)((want - top) * rh));
            return;
            }
        SetScrollPos(c, (i32)SB_VERT, px, (i32)1);
        InvalidateRect(c, (pointer)0, (i32)1);
        UpdateWindow(c);
        }
    i32 nativeScrollPx(pointer h, i32 node)
        {
        i32 isList = (i32)0;
        pointer c = self.scrollContainer(h, node, &isList);
        if (c == (pointer)0)
            {
            return (i32)0;
            }
        if (isList != (i32)0)
            {
            i32 rh = self.listRowHeight(c);
            return rh <= (i32)0 ? (i32)0
                                : (i32)SendMessageA(c, (u32)LVM_GETTOPINDEX, (pointer)0, (pointer)0) * rh;
            }
        return GetScrollPos(c, (i32)SB_VERT);
        }
    void structFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        W32Node* n = &((W32Tree*)h).nodes[i];
        x[0] = (i32)n.x;
        y[0] = (i32)n.y;
        w[0] = (i32)n.w;
        ht[0] = (i32)n.h;
        }
    void structSetHidden(pointer h, i32 i, i32 on)
        {
        ((W32Tree*)h).nodes[i].hidden = (i16)on;
        self.pushHiddenSubtree(h, i);
        }

    // HIDDEN IS INHERITED — see UXAppKitDriver.effectiveHidden for the full
    // reasoning.  In short: a native control is its own platform view, so it
    // does not disappear because an ancestor did; the app-drawn walk skips a
    // hidden subtree while native controls stayed visible, and the two halves
    // of one tree disagreed about what "hidden" means.
    //
    // VERIFIED on Win32 by test_hiddeninherit_win32.xc (gate `hiddeninherit-win32`):
    // a container of native controls, hidden AFTER realize, swapped both ways.
    // Node 0 is the root.  Walking parents must reach it; hitting -1 first
    // means this node was removed from the tree and is merely still occupying
    // its slot in the array.
    i32 isDetached(pointer h, i32 i)
        {
        W32Node* t = ((W32Tree*)h).nodes;
        i32 cur = i;
        i32 guard = (i32)0;
        while (guard <= (i32)256)
            {
            // reached the root
            if (cur == (i32)0)
                {
                return (i32)0;
                }
            if (t[cur].parent < (i16)0)
                {
                return (i32)1;
                }
            cur = (i32)t[cur].parent;
            guard = guard + (i32)1;
            }
        return (i32)0;
        }
    i32 effectiveHidden(pointer h, i32 i)
        {
        W32Node* t = ((W32Tree*)h).nodes;
        // DETACHED COUNTS AS HIDDEN.  structRemoveChild unlinks a node and
        // leaves parent = -1, but realizeTree walks every node in the array,
        // and structAbsFrame on a parentless node returns its LOCAL
        // coordinates — so a removed view was re-realized at the window's
        // top-left, on top of everything.  A node that cannot be reached from
        // the root is not in the interface, so it is not shown.
        if (self.isDetached(h, i) != (i32)0)
            {
            return (i32)1;
            }
        i32 cur = i;
        i32 guard = (i32)0;
        while (cur >= (i32)0 && guard <= (i32)256)
            {
            if (t[cur].hidden != (i16)0)
                {
                return (i32)1;
                }
            cur = (i32)t[cur].parent;
            guard = guard + (i32)1; // a malformed tree must not hang the UI
            }
        return (i32)0;
        }
    // Push the effective state to a node and everything under it, so hiding a
    // container takes effect on the next paint rather than the next realize.
    void pushHiddenSubtree(pointer h, i32 i)
        {
        W32Tree* t = (W32Tree*)h;
        if (i < (i32)0 || i >= t.count)
            {
            return;
            }
        if (t.nodes[i].ctrl != (pointer)0)
            {
            ShowWindow(t.nodes[i].ctrl, self.effectiveHidden(h, i) != (i32)0 ? (i32)0 : (i32)SW_SHOW);
            }
        i32 c = (i32)t.nodes[i].head;
        i32 guard = (i32)0;
        while (c >= (i32)0 && c < t.count && guard <= t.count)
            {
            self.pushHiddenSubtree(h, c);
            c = (i32)t.nodes[c].next;
            guard = guard + (i32)1;
            }
        }
    i32 structIsHidden(pointer h, i32 i)
        {
        return (i32)((W32Tree*)h).nodes[i].hidden;
        }
    void structSetEnabled(pointer h, i32 i, i32 on)
        {
        ((W32Tree*)h).nodes[i].enabled = (i16)on;
        pointer c = ((W32Tree*)h).nodes[i].ctrl;
        if (c != (pointer)0)
            {
            EnableWindow(c, on);
            }
        }
    i32 structIsEnabled(pointer h, i32 i)
        {
        return (i32)((W32Tree*)h).nodes[i].enabled;
        }
    void structSetSelected(pointer h, i32 i, i32 on)
        {
        ((W32Tree*)h).nodes[i].selected = (i16)on;
        }
    i32 structIsSelected(pointer h, i32 i)
        {
        return (i32)((W32Tree*)h).nodes[i].selected;
        }
    void structSetClips(pointer h, i32 i, i32 on)
        {
        ((W32Tree*)h).nodes[i].clips = (i16)on;
        }
    void structSetClipShape(pointer h, i32 i, i32 radius, i32 inset)
        {
        ((W32Tree*)h).nodes[i].clipR = (i16)radius;
        ((W32Tree*)h).nodes[i].clipIn = (i16)inset;
        }
    void structSetSpec(pointer h, i32 i, pointer spec)
        {
        ((W32Tree*)h).nodes[i].spec = spec;
        }
    // checkbox/radio state
    void structSetPeer(pointer h, i32 i, pointer peer)
        {
        ((W32Tree*)h).nodes[i].peer = peer;
        }
    // Win32 driver draws fixed layouts
    void structSetAutoresize(pointer h, i32 i, i32 mask)
        {
        }
    // the neutral layer lays Win32 out
    bool driverAutoresizes(void)
        {
        return false;
        }
    void structSetSelectable(pointer h, i32 i, i32 on)
        {
        ((W32Tree*)h).nodes[i].selectable = (i16)on;
        }
    void structSetEditable(pointer h, i32 i, i32 on)
        {
        ((W32Tree*)h).nodes[i].editable = (i16)on;
        }

    void treeOffset(pointer tree, i32 obj, i32* ax, i32* ay)
        {
        ax[0] = (i32)0;
        ay[0] = (i32)0;
        }
    void structAbsFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
        {
        W32Node* t = ((W32Tree*)h).nodes;
        i32 ax = (i32)t[i].x;
        i32 ay = (i32)t[i].y;
        i16 p = t[i].parent;
        while (p >= (i16)0)
            {
            ax = ax + (i32)t[p].x;
            ay = ay + (i32)t[p].y;
            p = t[p].parent;
            }
        x[0] = ax;
        y[0] = ay;
        w[0] = (i32)t[i].w;
        ht[0] = (i32)t[i].h;
        }

    // Deepest visible node whose ABSOLUTE rect contains (px,py), or -1.  (objc_find, in xtc.)
    i32 hitOne(W32Node* t, i32 i, i32 ox, i32 oy, i32 px, i32 py)
        {
        if (i < (i32)0 || t[i].hidden != (i16)0)
            {
            return (i32)-1;
            }
        i32 ax = ox + (i32)t[i].x;
        i32 ay = oy + (i32)t[i].y;
        i32 inside = (px >= ax && px < ax + (i32)t[i].w && py >= ay && py < ay + (i32)t[i].h) ? (i32)1 : (i32)0;
        i32 best = inside != (i32)0 ? i : (i32)-1; // this node, if hit
        i16 c = t[i].head;                         // a child hit wins (deeper)
        while (c >= (i16)0)
            {
            i32 hc = self.hitOne(t, (i32)c, ax, ay, px, py);
            if (hc >= (i32)0)
                {
                best = hc;
                }
            c = t[c].next;
            }
        return best;
        }
    i32 treeHitTest(pointer tree, i32 start, i32 x, i32 y)
        {
        return self.hitOne(((W32Tree*)tree).nodes, start, (i32)0, (i32)0, x, y);
        }

    // ---- painting ------------------------------------------------------------
    void treeSetUserDraw(pointer fn, pointer ud)
        {
        gW32UserFn = fn;
        gW32UserUd = ud;
        }
    // Reconcile native child controls with the shadow tree — the Win32 twin of AppKit's realizeTree.
    // Create the missing HWNDs (real BUTTON/… so the OS owns the look), reposition the rest.  Called
    // from UXWindow.display/displayAll, outside WM_PAINT.
    // True if any ancestor of node i is a table/outline: the native SysListView32 / SysTreeView32
    // overlays that whole subtree (rows AND the internal scroll), so nothing under it may be realized
    // as its own native control — an overlapping UXScroll32 would cover the tree and steal its clicks.
    i32 isUnderTable(W32Tree* t, i32 i)
        {
        i16 p = t.nodes[i].parent;
        while (p >= (i16)0)
            {
            if (t.nodes[p].kind == (i32)UXKindTable)
                {
                return (i32)1;
                }
            p = t.nodes[p].parent;
            }
        return (i32)0;
        }

    // ---- native ToolbarWindow32 (UXToolbar button row + UXSegmentedControl check-group) ----------
    // A ToolbarWindow32 normally snaps to the top of its parent; the CCS_NORESIZE|NOPARENTALIGN|NODIVIDER
    // trio pins it to the frame the neutral layout computed.  TB_BUTTONSTRUCTSIZE MUST precede any button.
    pointer w32MakeToolbar(pointer parent, i32 nodeIdx, i32 ax, i32 ay, i32 w, i32 hh)
        {
        u32 st = (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)TBSTYLE_LIST | (u32)CCS_NORESIZE | (u32)CCS_NOPARENTALIGN | (u32)CCS_NODIVIDER;
        pointer c = CreateWindowExA((u32)0, (pointer) "ToolbarWindow32", (pointer) "",
                                    st, ax, ay, w, hh, parent, (pointer)(W32_CTRL_ID_BASE + nodeIdx), gW32Inst, (pointer)0);
        SendMessageA(c, (u32)TB_BUTTONSTRUCTSIZE, (pointer)32, (pointer)0); // sizeof(TBBUTTON) on Win64
        SendMessageA(c, (u32)WM_SETFONT, gW32Font, (pointer)1);
        return c;
        }
    void w32TbbInit(TBBUTTON* b)
        {
        b.iBitmap = (i32)0;
        b.idCommand = (i32)0;
        b.fsState = (u8)0;
        b.fsStyle = (u8)0;
        b.r0 = (u8)0;
        b.r1 = (u8)0;
        b.r2 = (u8)0;
        b.r3 = (u8)0;
        b.r4 = (u8)0;
        b.r5 = (u8)0;
        b.dwData = (pointer)0;
        b.iString = (pointer)0;
        }
    // Add one text button.  TB_ADDSTRINGA registers the label (double-NUL-terminated list) and returns an
    // index the button's iString points at.  Labels are treated as ANSI here — fine for ASCII controls.
    // image = a standard-image index (STD_*), or -2 (I_IMAGENONE) for no icon (the segmented check-group).
    void w32ToolbarAdd(pointer tb, i32 idCommand, u8* label, i32 fsStyle, i32 checked, i32 image)
        {
        u8 buf[128];
        i32 n = (i32)0;
        while (label[n] != (u8)0 && n < (i32)126)
            {
            buf[n] = label[n];
            n = n + (i32)1;
            }
        buf[n] = (u8)0;
        buf[n + (i32)1] = (u8)0;
        i32 si = (i32)SendMessageA(tb, (u32)TB_ADDSTRINGA, (pointer)0, (pointer)&buf[0]);
        TBBUTTON b;
        self.w32TbbInit(&b);
        b.iBitmap = image;
        b.idCommand = idCommand;
        b.fsState = (u8)((u32)TBSTATE_ENABLED | (checked != (i32)0 ? (u32)TBSTATE_CHECKED : (u32)0));
        b.fsStyle = (u8)fsStyle;
        b.iString = (pointer)si;
        SendMessageA(tb, (u32)TB_ADDBUTTONS, (pointer)1, (pointer)&b);
        }
    // Map a neutral toolbar item's ident to a standard system-toolbar bitmap (parity with the mac
    // NSToolbar's per-item symbol).  Unknown idents get a generic "properties" tile rather than nothing.
    // 1 if s starts with p
    i32 idPfx(u8* s, u8* p)
        {
        i32 i = (i32)0;
        while (p[i] != (u8)0)
            {
            if (s[i] != p[i])
                {
                return (i32)0;
                }
            i = i + (i32)1;
            }
        return (i32)1;
        }
    i32 w32StdImage(u8* ident)
        {
        if (self.idPfx(ident, (u8*)"new") != (i32)0)
            {
            return (i32)TBI_NEW;
            }
        if (self.idPfx(ident, (u8*)"opn") != (i32)0 || self.idPfx(ident, (u8*)"open") != (i32)0)
            {
            return (i32)TBI_OPEN;
            }
        if (self.idPfx(ident, (u8*)"del") != (i32)0)
            {
            return (i32)TBI_DELETE;
            }
        return (i32)TBI_GENERIC;
        }

    // ---- the hand-drawn toolbar image list ---------------------------------------------------------
    // Fill a colour block in a memory DC (COLORREF is 0x00BBGGRR).  A brush per call — cheap; runs 4x/glyph.
    void w32FillRC(pointer hdc, i32 x, i32 y, i32 w, i32 h, u32 color)
        {
        RECT r;
        r.left = x;
        r.top = y;
        r.right = x + w;
        r.bottom = y + h;
        pointer br = CreateSolidBrush(color);
        FillRect(hdc, (pointer)&r, br);
        DeleteObject(br);
        }
    // Draw one 16x16 glyph (kind = TBI_*) over the dialog-face background, so it blends into the button.
    void w32DrawGlyph(pointer hdc, i32 kind)
        {
        self.w32FillRC(hdc, (i32)0, (i32)0, (i32)16, (i32)16, (u32)$00C0C0C0); // face-grey backdrop
        // a white page with grey text lines
        if (kind == (i32)TBI_NEW)
            {
            self.w32FillRC(hdc, (i32)3, (i32)1, (i32)10, (i32)14, (u32)$00FFFFFF);
            self.w32FillRC(hdc, (i32)3, (i32)1, (i32)10, (i32)1, (u32)$00808080);  // frame: top
            self.w32FillRC(hdc, (i32)3, (i32)14, (i32)10, (i32)1, (u32)$00808080); // bottom
            self.w32FillRC(hdc, (i32)3, (i32)1, (i32)1, (i32)14, (u32)$00808080);  // left
            self.w32FillRC(hdc, (i32)12, (i32)1, (i32)1, (i32)14, (u32)$00808080); // right
            self.w32FillRC(hdc, (i32)5, (i32)4, (i32)6, (i32)1, (u32)$00808080);
            self.w32FillRC(hdc, (i32)5, (i32)7, (i32)6, (i32)1, (u32)$00808080);
            self.w32FillRC(hdc, (i32)5, (i32)10, (i32)6, (i32)1, (u32)$00808080);
            }
        // a manila folder (tab + body)
        else if (kind == (i32)TBI_OPEN)
            {
            self.w32FillRC(hdc, (i32)2, (i32)4, (i32)5, (i32)2, (u32)$0050AAD2);
            self.w32FillRC(hdc, (i32)2, (i32)6, (i32)12, (i32)7, (u32)$0082D0F0);
            }
        // a red chip with a white bar
        else if (kind == (i32)TBI_DELETE)
            {
            self.w32FillRC(hdc, (i32)3, (i32)3, (i32)10, (i32)10, (u32)$000000C0);
            self.w32FillRC(hdc, (i32)5, (i32)7, (i32)6, (i32)2, (u32)$00FFFFFF);
            }
        // a steel-blue chip
        else
            {
            self.w32FillRC(hdc, (i32)3, (i32)3, (i32)10, (i32)10, (u32)$00A08060);
            }
        }
    // Build the shared image list once: a 16x16 bitmap per glyph, drawn into a memory DC, added in order.
    pointer w32IconList(void)
        {
        if (gW32TbImages != (pointer)0)
            {
            return gW32TbImages;
            }
        pointer himl = ImageList_Create((i32)16, (i32)16, (u32)ILC_COLOR32, (i32)4, (i32)0);
        pointer scr = GetDC((pointer)0);
        for (i32 k = (i32)0; k < (i32)4; k = k + (i32)1)
            {
            pointer memdc = CreateCompatibleDC(scr);
            pointer bmp = CreateCompatibleBitmap(scr, (i32)16, (i32)16);
            pointer old = SelectObject(memdc, bmp);
            self.w32DrawGlyph(memdc, k);
            SelectObject(memdc, old);
            ImageList_Add(himl, bmp, (pointer)0);
            DeleteObject(bmp);
            DeleteDC(memdc);
            }
        ReleaseDC((pointer)0, scr);
        gW32TbImages = himl;
        return himl;
        }
    void w32ToolbarAddSep(pointer tb)
        {
        TBBUTTON b;
        self.w32TbbInit(&b);
        b.iBitmap = (i32)8; // separator width in pixels
        b.fsState = (u8)TBSTATE_ENABLED;
        b.fsStyle = (u8)BTNS_SEP;
        SendMessageA(tb, (u32)TB_ADDBUTTONS, (pointer)1, (pointer)&b);
        }
    // A control's text alignment, read from its PEER (alignment lives on the
    // control, not in the shadow tree).  Pushed by rewriting the STATIC/EDIT
    // style bits, because Win32 carries alignment in the style rather than as a
    // settable property -- so the control must also be told to repaint.
    //
    // NOT VERIFIED ON REAL WINDOWS: written against the Win32 documentation and
    // smoke-tested under wine.  When a Windows box is to hand, check a column of
    // right-aligned labels lines its colons up.
    i32 alignOf(pointer peer)
        {
        UXControl* c = (UXControl* ?)(Object*)peer;
        if (c == (UXControl*)0)
            {
            return (i32)UX_ALIGN_LEFT;
            }
        return c.alignment();
        }
    void pushAlign(pointer ctrl, i32 kind, i32 a)
        {
        if (ctrl == (pointer)0)
            {
            return;
            }
        i32 bits = a == (i32)UX_ALIGN_RIGHT    ? (i32)SS_RIGHT
                   : a == (i32)UX_ALIGN_CENTER ? (i32)SS_CENTER
                                               : (i32)SS_LEFT;
        if (kind == (i32)UXKindField)
            {
            bits = a == (i32)UX_ALIGN_RIGHT    ? (i32)ES_RIGHT
                   : a == (i32)UX_ALIGN_CENTER ? (i32)ES_CENTER
                                               : (i32)0;
            }
        pointer st = GetWindowLongPtrA(ctrl, (i32)GWL_STYLE);
        u32 cleared = (u32)st & ~(u32)3; // both families use the low 2 bits
        SetWindowLongPtrA(ctrl, (i32)GWL_STYLE, (pointer)(cleared | (u32)bits));
        InvalidateRect(ctrl, (pointer)0, (i32)1);
        }

    // ---- the native text view (UXTextView): a RichEdit; the undo is the view's own --------------
    void textViewSetAll(i32 handle, i32 node, u8* text, i32 nbytes, i32* runs, i32 nruns)
        {
        W32TextView* r = W32TextView.at(handle, node);
        if (r != (W32TextView*)0)
            {
            r.setAll(text, nbytes, runs, nruns);
            }
        }
    void textViewReplace(i32 handle, i32 node, i32 start, i32 len, u8* text, i32 nbytes, i32* runs, i32 nruns,
                         i32 attrsOnly)
        {
        W32TextView* r = W32TextView.at(handle, node);
        if (r != (W32TextView*)0)
            {
            r.replace(start, len, text, nbytes, runs, nruns, attrsOnly);
            }
        }
    void textViewSize(i32 handle, i32 node, i32* nbytes, i32* nruns)
        {
        W32TextView* r = W32TextView.at(handle, node);
        nbytes[0] = (i32)0;
        nruns[0] = (i32)0;
        if (r != (W32TextView*)0)
            {
            nruns[0] = r.walk((u8*)0, (i32)0, (i32*)0, (i32)0, nbytes);
            }
        }
    i32 textViewRead(i32 handle, i32 node, u8* buf, i32 cap, i32* runs, i32 maxRuns)
        {
        W32TextView* r = W32TextView.at(handle, node);
        if (r == (W32TextView*)0 || cap <= (i32)0)
            {
            return (i32)0;
            }
        i32 k = r.walk(buf, cap, runs, maxRuns, (i32*)0);
        return k < maxRuns ? k : maxRuns;
        }
    void textViewSelection(i32 handle, i32 node, i32* start, i32* len)
        {
        W32TextView* r = W32TextView.at(handle, node);
        start[0] = (i32)0;
        len[0] = (i32)0;
        if (r != (W32TextView*)0)
            {
            r.selectionBytes(start, len);
            }
        }
    void textViewSetSelection(i32 handle, i32 node, i32 start, i32 len)
        {
        W32TextView* r = W32TextView.at(handle, node);
        if (r != (W32TextView*)0)
            {
            r.setSelectionBytes(start, len);
            }
        }
    void textViewSetTyping(i32 handle, i32 node, i32 flags, i32 colour, i32 size)
        {
        W32TextView* r = W32TextView.at(handle, node);
        if (r != (W32TextView*)0)
            {
            r.setTyping(flags, colour, size);
            }
        }
    void textViewFocus(i32 handle, i32 node)
        {
        W32TextView* r = W32TextView.at(handle, node);
        if (r != (W32TextView*)0)
            {
            SetFocus(r.hwnd);
            }
        }

    void realizeTree(i32 handle, pointer tree)
        {
        W32Tree* t = (W32Tree*)tree;
        pointer parent = gW32Hwnds[handle];
        if (handle > (i32)0 && handle < (i32)64)
            {
            gW32TreeOf[handle] = tree;
            }
        for (i32 i = (i32)0; i < t.count; i = i + (i32)1)
            {
            i32 k = t.nodes[i].kind;
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 w = (i32)0;
            i32 hh = (i32)0;
            self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
            if (k == (i32)UXKindTextView)
                {
                if (t.nodes[i].ctrl == (pointer)0)
                    {
                    UXTextView* tvp = (UXTextView* ?)(Object*)t.nodes[i].peer;
                    W32TextView* rv = W32TextView.make(handle, i, parent, ax, ay, w, hh, tvp);
                    if (rv != (W32TextView*)0)
                        {
                        t.nodes[i].ctrl = rv.hwnd;
                        if (tvp != (UXTextView*)0)
                            {
                            tvp.nativeAttach(handle, i);
                            }
                        }
                    }
                else
                    {
                    MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                    ShowWindow(t.nodes[i].ctrl, self.effectiveHidden(tree, i) != (i32)0 ? (i32)0 : (i32)SW_SHOW);
                    EnableWindow(t.nodes[i].ctrl, (i32)t.nodes[i].enabled);
                    }
                }
            else if (k == (i32)UXKindShield)
                {
                if (t.nodes[i].ctrl == (pointer)0)
                    {
                    pointer c = CreateWindowExA((u32)0, (pointer) "UXShield32", (pointer) "",
                                                (u32)WS_CHILD | (u32)WS_VISIBLE,
                                                ax, ay, w, hh, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                    SetWindowLongPtrA(c, (i32)GWLP_USERDATA, t.nodes[i].peer); // for the coord translation
                    t.nodes[i].ctrl = c;
                    }
                else
                    {
                    MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                    }
                gW32Shield[handle] = t.nodes[i].ctrl;
                ShowWindow(t.nodes[i].ctrl, self.effectiveHidden(tree, i) != (i32)0 ? (i32)0 : (i32)SW_SHOW);
                }
            else if (k == (i32)UXKindGLView)
                {
                // The surface, made with the tree and not before: a GL view that never calls
                // makeGL still pays for a child window, which is the price of having one the
                // driver owns.  The context is NOT made here -- that is makeGLContext's job.
                // The attach is tried on EVERY realization, because the view's peer only
                // exists from makeGL on: the child window is made on the first realization
                // and the SURFACE is taken on the one that follows the first makeGL.
                if (t.nodes[i].ctrl == (pointer)0)
                    {
                    pointer c = CreateWindowExA((u32)0, (pointer) "UXGl32", (pointer) "",
                                                (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)WS_CLIPSIBLINGS,
                                                ax, ay, w, hh, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                    t.nodes[i].ctrl = c;
                    w32_gl_attach(t.nodes[i].peer, c);
                    }
                else
                    {
                    MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                    w32_gl_attach(t.nodes[i].peer, t.nodes[i].ctrl);
                    w32_gl_viewport(t.nodes[i].peer);
                    }
                // An OFFSCREEN surface's child stays hidden: the frame is blitted by the paint, and a
                // visible child would clip it (and everything drawn over it) away.
                i32 gi = w32_gl_find(t.nodes[i].peer);
                bool offscreen = gi >= (i32)0 && gW32GlOff[gi] != (i32)0;
                ShowWindow(t.nodes[i].ctrl, (self.effectiveHidden(tree, i) != (i32)0 || offscreen) ? (i32)0 : (i32)SW_SHOW);
                }
            else if (k == (i32)UXKindButton)
                {
                if (t.nodes[i].ctrl == (pointer)0)
                    {
                    u8* title = t.nodes[i].spec != (pointer)0 ? (u8*)t.nodes[i].spec : (u8*)"";
                    pointer c = CreateWindowExA((u32)0, (pointer) "BUTTON", (pointer)title,
                                                (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)WS_TABSTOP | (u32)BS_PUSHBUTTON,
                                                ax, ay, w, hh, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                    SendMessageA(c, (u32)WM_SETFONT, gW32Font, (pointer)1);
                    SetWindowLongPtrA(c, (i32)GWLP_USERDATA, t.nodes[i].peer); // the UXButton -> fire on click
                    t.nodes[i].ctrl = c;
                    }
                else
                    {
                    MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                    w32SyncText(t.nodes[i].ctrl, (u8*)t.nodes[i].spec); // a title changed since
                    }
                }
            else if (k == (i32)UXKindField)
                {
                W32Field* f = (W32Field*)t.nodes[i].spec;
                // A single-line EDIT does NOT vertically-centre text in a tall control (it sits at the
                // top), so give it a text-height box centred in the field's frame.
                i32 eh = (i32)20;
                i32 ey = ay + (hh - eh) / (i32)2;
                if (t.nodes[i].ctrl == (pointer)0)
                    {
                    u8* init = f != (W32Field*)0 ? (u8*)&f.buf[0] : (u8*)"";
                    u32 est = (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)WS_BORDER | (u32)WS_TABSTOP | (u32)ES_AUTOHSCROLL;
                    // •••• masking
                    if (f != (W32Field*)0 && f.secure != (i32)0)
                        {
                        est = est | (u32)ES_PASSWORD;
                        }
                    pointer c = CreateWindowExA((u32)0, (pointer) "EDIT", (pointer)init, est,
                                                ax, ey, w, eh, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                    SendMessageA(c, (u32)WM_SETFONT, gW32Font, (pointer)1);
                    SetWindowLongPtrA(c, (i32)GWLP_USERDATA, (pointer)f); // so EN_CHANGE can sync the buffer
                    f.field = (pointer)t.nodes[i].peer;                   // and reach the field for onChange
                    // grey cue banner while empty
                    if (f.place != (u8*)0)
                        {
                        u16 wbuf[256];
                        i32 wch = MultiByteToWideChar((u32)CP_UTF8, (u32)0, (pointer)f.place, (i32)-1, (pointer)&wbuf[0], (i32)256);
                        if (wch > (i32)1)
                            {
                            SendMessageA(c, (u32)EM_SETCUEBANNER, (pointer)1, (pointer)&wbuf[0]);
                            }
                        }
                    t.nodes[i].ctrl = c;
                    }
                else
                    {
                    MoveWindow(t.nodes[i].ctrl, ax, ey, w, eh, (i32)1);
                    }
                // Push the model buffer into the EDIT when the app changed it (e.g. Clear): only if it
                // differs, so this never fights live typing (which keeps buffer == EDIT via EN_CHANGE).
                if (f != (W32Field*)0)
                    {
                    u8 cur[256];
                    GetWindowTextA(t.nodes[i].ctrl, (pointer)&cur[0], (i32)256);
                    if (self.strdiff(&cur[0], &f.buf[0]) != (i32)0)
                        {
                        SetWindowTextA(t.nodes[i].ctrl, (pointer)&f.buf[0]);
                        }
                    }
                }
            else if (k == (i32)UXKindCheckbox || k == (i32)UXKindRadio)
                {
                // A native check box / radio button.  The OS draws it (round radio, ticked box) in the
                // OS style; the neutral widget still owns the state + (for radios) group exclusion, so
                // realizeTree pushes that state into the control with BM_SETCHECK every display.
                i32 style = k == (i32)UXKindRadio ? (i32)BS_AUTORADIOBUTTON : (i32)BS_AUTOCHECKBOX;
                if (t.nodes[i].ctrl == (pointer)0)
                    {
                    u8* title = t.nodes[i].spec != (pointer)0 ? (u8*)t.nodes[i].spec : (u8*)"";
                    pointer c = CreateWindowExA((u32)0, (pointer) "BUTTON", (pointer)title,
                                                (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)WS_TABSTOP | (u32)style,
                                                ax, ay, w, hh, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                    SendMessageA(c, (u32)WM_SETFONT, gW32Font, (pointer)1);
                    SetWindowLongPtrA(c, (i32)GWLP_USERDATA, t.nodes[i].peer); // the UXCheckbox/UXRadioButton
                    t.nodes[i].ctrl = c;
                    }
                else
                    {
                    MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                    w32SyncText(t.nodes[i].ctrl, (u8*)t.nodes[i].spec); // a title changed since
                    }
                i32 on = self.toggleState(t.nodes[i].peer, k);
                SendMessageA(t.nodes[i].ctrl, (u32)BM_SETCHECK, (pointer)on, (pointer)0); // model -> visual
                }
            else if (k == (i32)UXKindSlider)
                {
                UXSlider* sv = (UXSlider* ?)(Object*)t.nodes[i].peer;
                if (sv != (UXSlider*)0)
                    {
                    if (t.nodes[i].ctrl == (pointer)0)
                        {
                        pointer c = CreateWindowExA((u32)0, (pointer) "msctls_trackbar32", (pointer) "",
                                                    (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)WS_TABSTOP | (u32)TBS_HORZ | (u32)TBS_AUTOTICKS,
                                                    ax, ay, w, hh, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                        SendMessageA(c, (u32)TBM_SETRANGEMIN, (pointer)0, (pointer)sv.nativeMin());
                        SendMessageA(c, (u32)TBM_SETRANGEMAX, (pointer)1, (pointer)sv.nativeMax());
                        SendMessageA(c, (u32)TBM_SETPOS, (pointer)1, (pointer)sv.nativeValue());
                        SetWindowLongPtrA(c, (i32)GWLP_USERDATA, (pointer)sv); // WM_HSCROLL -> the slider
                        t.nodes[i].ctrl = c;
                        }
                    else
                        {
                        MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                        SendMessageA(t.nodes[i].ctrl, (u32)TBM_SETPOS, (pointer)1, (pointer)sv.nativeValue());
                        }
                    }
                }
            else if (k == (i32)UXKindPopup)
                {
                UXPopUpButton* pv = (UXPopUpButton* ?)(Object*)t.nodes[i].peer;
                if (pv != (UXPopUpButton*)0)
                    {
                    if (t.nodes[i].ctrl == (pointer)0)
                        {
                        // the combo's height must include the dropped-down list, so add headroom
                        pointer c = CreateWindowExA((u32)0, (pointer) "COMBOBOX", (pointer) "",
                                                    (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)WS_TABSTOP | (u32)WS_VSCROLL | (u32)CBS_DROPDOWNLIST,
                                                    ax, ay, w, hh + (i32)120, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                        SendMessageA(c, (u32)WM_SETFONT, gW32Font, (pointer)1);
                        for (i32 j = (i32)0; j < pv.nativeItemCount(); j = j + (i32)1)
                            {
                            SendMessageA(c, (u32)CB_ADDSTRING, (pointer)0, (pointer)pv.nativeItemTitle(j));
                            }
                        SendMessageA(c, (u32)CB_SETCURSEL, (pointer)pv.nativeSelected(), (pointer)0);
                        SetWindowLongPtrA(c, (i32)GWLP_USERDATA, (pointer)pv); // CBN_SELCHANGE -> the popup
                        t.nodes[i].ctrl = c;
                        }
                    else
                        {
                        MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh + (i32)120, (i32)1);
                        SendMessageA(t.nodes[i].ctrl, (u32)CB_SETCURSEL, (pointer)pv.nativeSelected(), (pointer)0);
                        }
                    }
                }
            else if (k == (i32)UXKindStepper)
                {
                UXStepper* sv = (UXStepper* ?)(Object*)t.nodes[i].peer;
                if (sv != (UXStepper*)0)
                    {
                    if (t.nodes[i].ctrl == (pointer)0)
                        {
                        pointer c = CreateWindowExA((u32)0, (pointer) "msctls_updown32", (pointer) "",
                                                    (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)UDS_ARROWKEYS,
                                                    ax, ay, w, hh, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                        SendMessageA(c, (u32)UDM_SETRANGE32, (pointer)sv.nativeMin(), (pointer)sv.nativeMax());
                        SendMessageA(c, (u32)UDM_SETPOS32, (pointer)0, (pointer)sv.nativeValue());
                        SetWindowLongPtrA(c, (i32)GWLP_USERDATA, (pointer)sv); // WM_VSCROLL -> the stepper
                        t.nodes[i].ctrl = c;
                        }
                    else
                        {
                        MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                        SendMessageA(t.nodes[i].ctrl, (u32)UDM_SETPOS32, (pointer)0, (pointer)sv.nativeValue());
                        }
                    }
                }
            else if (k == (i32)UXKindProgress)
                {
                UXProgressBar* pgv = (UXProgressBar* ?)(Object*)t.nodes[i].peer;
                if (pgv != (UXProgressBar*)0)
                    {
                    if (t.nodes[i].ctrl == (pointer)0)
                        {
                        pointer c = CreateWindowExA((u32)0, (pointer) "msctls_progress32", (pointer) "",
                                                    (u32)WS_CHILD | (u32)WS_VISIBLE,
                                                    ax, ay, w, hh, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                        SendMessageA(c, (u32)PBM_SETRANGE32, (pointer)0, (pointer)1000);
                        t.nodes[i].ctrl = c;
                        }
                    else
                        {
                        MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                        }
                    SendMessageA(t.nodes[i].ctrl, (u32)PBM_SETPOS, (pointer)pgv.nativeFractionMille(), (pointer)0);
                    }
                }
            else if (k == (i32)UXKindSegmented)
                {
                UXSegmentedControl* sg = (UXSegmentedControl* ?)(Object*)t.nodes[i].peer;
                if (sg != (UXSegmentedControl*)0)
                    {
                    if (t.nodes[i].ctrl == (pointer)0)
                        {
                        // CHECKGROUP = radio (single); CHECK = independent toggles (multi).  Win32 enforces
                        // the exclusion, and applyNativeSelection mirrors either into the model.
                        i32 bstyle = (sg.nativeMultiSelect() != (i32)0 ? (i32)BTNS_CHECK : (i32)BTNS_CHECKGROUP) | (i32)BTNS_SHOWTEXT | (i32)BTNS_AUTOSIZE;
                        pointer c = self.w32MakeToolbar(parent, i, ax, ay, w, hh);
                        // no icons on a segmented control
                        for (i32 j = (i32)0; j < sg.nativeSegCount(); j = j + (i32)1)
                            {
                            self.w32ToolbarAdd(c, j, sg.nativeSegLabel(j), bstyle, sg.nativeSegSelected(j), (i32)-2);
                            }
                        SendMessageA(c, (u32)TB_AUTOSIZE, (pointer)0, (pointer)0);
                        SetWindowLongPtrA(c, (i32)GWLP_USERDATA, (pointer)sg); // WM_COMMAND -> the segmented control
                        t.nodes[i].ctrl = c;
                        }
                    else
                        {
                        MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                        // model -> visual
                        for (i32 j = (i32)0; j < sg.nativeSegCount(); j = j + (i32)1)
                            {
                            SendMessageA(t.nodes[i].ctrl, (u32)TB_CHECKBUTTON, (pointer)j, (pointer)sg.nativeSegSelected(j));
                            }
                        }
                    }
                }
            else if (k == (i32)UXKindToolbar)
                {
                UXToolbar* tbw = (UXToolbar* ?)(Object*)t.nodes[i].peer;
                if (tbw != (UXToolbar*)0)
                    {
                    if (t.nodes[i].ctrl == (pointer)0)
                        {
                        pointer c = self.w32MakeToolbar(parent, i, ax, ay, w, hh);
                        // Attach our hand-drawn 16x16 glyphs (New/Open/Delete/generic), the Win32 counterpart
                        // of the mac NSToolbar's per-item symbol.  (Wine's TB_LOADIMAGES gives an empty list.)
                        SendMessageA(c, (u32)TB_SETIMAGELIST, (pointer)0, self.w32IconList());
                        for (i32 j = (i32)0; j < tbw.nativeItemCount(); j = j + (i32)1)
                            {
                            if (tbw.nativeItemType(j) == (i32)UXTB_ITEM)
                                {
                                self.w32ToolbarAdd(c, tbw.nativeItemTag(j), tbw.nativeItemLabel(j),
                                                   (i32)BTNS_BUTTON | (i32)BTNS_SHOWTEXT | (i32)BTNS_AUTOSIZE, (i32)0,
                                                   self.w32StdImage(tbw.nativeItemIdent(j)));
                                }
                            else
                                {
                                self.w32ToolbarAddSep(c); // space / flex / separator -> a native gap
                                }
                            }
                        SendMessageA(c, (u32)TB_AUTOSIZE, (pointer)0, (pointer)0);
                        SetWindowLongPtrA(c, (i32)GWLP_USERDATA, (pointer)tbw); // WM_COMMAND -> the toolbar
                        t.nodes[i].ctrl = c;
                        }
                    else
                        {
                        MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                        }
                    }
                }
            else if (k == (i32)UXKindTable)
                {
                UXTableView* tv = (UXTableView* ?)(Object*)t.nodes[i].peer;
                if (t.nodes[i].ctrl == (pointer)0)
                    {
                    if (tv != (UXTableView*)0 && tv.nativeIsOutline() != (i32)0)
                        {
                        // A native TREE: SysTreeView32, populated from the outline's item hooks.
                        u32 tvs = (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)WS_BORDER | (u32)TVS_HASBUTTONS | (u32)TVS_HASLINES | (u32)TVS_LINESATROOT | (u32)TVS_SHOWSELALWAYS;
                        pointer c = CreateWindowExA((u32)0, (pointer) "SysTreeView32", (pointer) "",
                                                    tvs, ax, ay, w, hh, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                        SendMessageA(c, (u32)WM_SETFONT, gW32Font, (pointer)1);
                        SetWindowLongPtrA(c, (i32)GWLP_USERDATA, (pointer)tv); // WM_NOTIFY maps back to the outline
                        t.nodes[i].ctrl = c;
                        self.treeFill(c, (UXOutlineView* ?)tv, (pointer)0, (pointer)0);   // NULL parent = root
                        }
                    else
                        {
                        u32 lvs = (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)WS_BORDER | (u32)LVS_REPORT | (u32)LVS_SHOWSELALWAYS;
                        if (tv == (UXTableView*)0 || tv.nativeAllowsMultiple() == (i32)0)
                            {
                            lvs = lvs | (u32)LVS_SINGLESEL;
                            }
                        if (tv != (UXTableView*)0 && self.untitled(tv))
                            {
                            lvs = lvs | (u32)LVS_NOCOLUMNHEADER; // no titles: no header row
                            }
                        pointer c = CreateWindowExA((u32)0, (pointer) "SysListView32", (pointer) "",
                                                    lvs, ax, ay, w, hh, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                        SendMessageA(c, (u32)WM_SETFONT, gW32Font, (pointer)1);
                        SendMessageA(c, (u32)LVM_SETEXTENDEDLISTVIEWSTYLE,
                                     (pointer)(LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES), (pointer)(LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES));
                        SetWindowLongPtrA(c, (i32)GWLP_USERDATA, (pointer)tv); // WM_NOTIFY maps back to the table
                        t.nodes[i].ctrl = c;
                        self.tableFill(c, tv);
                        }
                    }
                else
                    {
                    MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                    // reloadData() only moved the toolkit's shadow rows; the native list still holds
                    // what it was filled with at creation.  Empty it and refill from the datasource,
                    // or a filtered table shows its original contents for ever.
                    // An OUTLINE is an UXTableView subclass on a SysTreeView32 — a ListView message
                    // would be meaningless there, and its rows come from the item hooks, not the
                    // table datasource.  Tables only.
                    if (tv != (UXTableView*)0 && tv.nativeIsOutline() == (i32)0 && tv.nativeNeedsReload())
                        {
                        SendMessageA(t.nodes[i].ctrl, (u32)LVM_DELETEALLITEMS, (pointer)0, (pointer)0);
                        self.tableFill(t.nodes[i].ctrl, tv);
                        tv.clearNativeReload();
                        }
                    // A selection the MODEL made (replay, app code) goes back into the native list.
                    // Only when the model asked for it: pushing on every realize would fight a user
                    // who is mid-click, and applyNativeSelection clears the flag precisely because a
                    // selection that came FROM the control needs no sending back.
                    if (tv != (UXTableView*)0 && tv.nativeIsOutline() == (i32)0 && tv.nativeSelectionNeedsPush())
                        {
                        self.tablePushSelection(t.nodes[i].ctrl, tv);
                        }
                    }
                }
            else if (k == (i32)UXKindScroll && self.isUnderTable(t, i) == (i32)0)
                {
                UXScrollView* sv = (UXScrollView* ?)(Object*)t.nodes[i].peer;
                i32 ch = sv != (UXScrollView*)0 ? sv.nativeContentHeight() : (i32)0;
                if (t.nodes[i].ctrl == (pointer)0)
                    {
                    u32 style = (u32)WS_CHILD | (u32)WS_VISIBLE | (u32)WS_VSCROLL | (u32)WS_BORDER;
                    pointer c = CreateWindowExA((u32)0, (pointer) "UXScroll32", (pointer) "",
                                                style, ax, ay, w, hh, parent, (pointer)(W32_CTRL_ID_BASE + i), gW32Inst, (pointer)0);
                    SetWindowLongPtrA(c, (i32)GWLP_USERDATA, (pointer)sv); // WM_PAINT reads the peer off this
                    SendMessageA(c, (u32)WM_SETFONT, gW32Font, (pointer)1);
                    w32ScrollerAdd(c, handle); // so windowInvalidate* reaches this child too
                    t.nodes[i].ctrl = c;
                    w32ScrollRange(c, ch, hh);
                    }
                else
                    {
                    MoveWindow(t.nodes[i].ctrl, ax, ay, w, hh, (i32)1);
                    w32ScrollRange(t.nodes[i].ctrl, ch, hh);
                    }
                // Rounded: the window region clips the child (and its bar) to the rounded shape, every
                // pass, as the size may have changed; square drops the region.  The system owns it.
                i32 cr = sv != (UXScrollView*)0 ? sv.nativeCornerRadius() : (i32)0;
                SetWindowRgn(t.nodes[i].ctrl,
                             cr > (i32)0 ? CreateRoundRectRgn((i32)0, (i32)0, w + (i32)1, hh + (i32)1, cr * (i32)2, cr * (i32)2)
                                         : (pointer)0, (i32)1);
                }
            // apply the node's INITIAL state to a control created THIS pass:
            // the model setters above only reach a ctrl that already exists,
            // and a widget disabled/hidden before its first realize stayed
            // pristine (the state-pair portraits caught it)
            if (t.nodes[i].ctrl != (pointer)0)
                {
                if (t.nodes[i].enabled == (i16)0)
                    {
                    EnableWindow(t.nodes[i].ctrl, (i32)0);
                    }
                if (self.effectiveHidden(tree, i) != (i32)0)
                    {
                    ShowWindow(t.nodes[i].ctrl, (i32)0);
                    }
                // Alignment every pass, not only the first: an editor changes it
                // after realize.
                if (k == (i32)UXKindLabel || k == (i32)UXKindField)
                    {
                    self.pushAlign(t.nodes[i].ctrl, k, self.alignOf(t.nodes[i].peer));
                    }
                }
            }
        // Controls created THIS pass went in above the shield, so put it back on
        // top of the sibling z-order.  A shield that works only until the next
        // widget appears works exactly as long as you are testing it.
        if (handle >= (i32)0 && handle < (i32)64 && gW32Shield[handle] != (pointer)0)
            {
            BringWindowToTop(gW32Shield[handle]);
            }
        }

    // Push the MODEL's selection into the native list — the direction that never worked.
    //
    // The trap: clearing "everything" with LVM_SETITEMSTATE and wParam -1 (the documented broadcast)
    // does nothing under Wine, exactly as LVM_GETNEXTITEM with -1 does nothing here, so the old rows
    // stayed selected and the control ended up holding the UNION of the old selection and the new
    // one.  Clearing row by row is O(rows) and actually works.  The echo guard covers the whole
    // operation, so the model is not overwritten by its own half-finished state.
    void tablePushSelection(pointer lv, UXTableView* tv)
        {
        i32 want[256];
        i32 n = tv.selectedRowList(&want[(i32)0], (i32)256);
        i32 count = (i32)SendMessageA(lv, (u32)LVM_GETITEMCOUNT, (pointer)0, (pointer)0);
        LVITEM it;
        it.mask = (u32)0;
        it.iSubItem = (i32)0;
        it.pszText = (pointer)0;
        it.cchTextMax = (i32)0;
        it.iImage = (i32)0;
        it.lParam = (pointer)0;
        it.iIndent = (i32)0;
        it.stateMask = (u32)LVIS_SELECTED;

        gW32SelPush = (i32)1;
        it.state = (u32)0; // clear, one row at a time
        for (i32 r = (i32)0; r < count; r = r + (i32)1)
            {
            it.iItem = r;
            SendMessageA(lv, (u32)LVM_SETITEMSTATE, (pointer)r, (pointer)&it);
            }
        it.state = (u32)LVIS_SELECTED; // then set exactly what the model holds
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            it.iItem = want[i];
            SendMessageA(lv, (u32)LVM_SETITEMSTATE, (pointer)want[i], (pointer)&it);
            }
        gW32SelPush = (i32)0;
        tv.clearNativeSelectionPush();
        }

    // Populate a fresh ListView with the peer table's columns + rows (same neutral datasource the
    // GEM/AppKit tables read).  Columns first (header), then a row per record, cell per column.
    void tableFill(pointer lv, UXTableView* tv)
        {
        if (tv == (UXTableView*)0)
            {
            return;
            }
        i32 ncol = tv.numberOfColumns();
        for (i32 c = (i32)0; c < ncol; c = c + (i32)1)
            {
            LVCOLUMN col;
            col.mask = (u32)(LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM);
            col.fmt = (i32)0;
            col.cx = (i32)tv.columnWidth(c);
            col.pszText = (pointer)tv.columnTitle(c);
            col.cchTextMax = (i32)0;
            col.iSubItem = c;
            col.iImage = (i32)0;
            col.iOrder = (i32)0;
            col._pad0 = (i32)0;
            SendMessageA(lv, (u32)LVM_INSERTCOLUMNA, (pointer)c, (pointer)&col);
            }
        i32 nrow = tv.nativeRowCount();
        for (i32 r = (i32)0; r < nrow; r = r + (i32)1)
            {
            LVITEM it;
            self.lvitemInit(&it);
            it.mask = (u32)LVIF_TEXT;
            it.iItem = r;
            it.iSubItem = (i32)0;
            it.pszText = (pointer)tv.nativeCellText(r, (i32)0);
            SendMessageA(lv, (u32)LVM_INSERTITEMA, (pointer)0, (pointer)&it);
            for (i32 c = (i32)1; c < ncol; c = c + (i32)1)
                {
                LVITEM si;
                self.lvitemInit(&si);
                si.mask = (u32)LVIF_TEXT;
                si.iItem = r;
                si.iSubItem = c;
                si.pszText = (pointer)tv.nativeCellText(r, c);
                SendMessageA(lv, (u32)LVM_SETITEMTEXTA, (pointer)r, (pointer)&si);
                }
            }
        }
    // Populate a SysTreeView32 from the outline's ITEM hooks: insert every child of `item` under
    // `hParent`, storing the item pointer as the TreeView item's lParam (so a selection/expand maps
    // back), and recurse.  Honour the neutral outline's initial expansion.
    void treeFill(pointer tv, UXOutlineView* o, pointer item, pointer hParent)
        {
        if (o == (UXOutlineView*)0)
            {
            return;
            }
        i32 n = o.nativeChildren(item);
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            pointer child = o.nativeChild(item, i);
            TVINSERTSTRUCT ins;
            ins.hParent = hParent;
            ins.hInsertAfter = (pointer)TVI_LAST;
            ins.mask = (u32)(TVIF_TEXT | TVIF_PARAM);
            ins._pad0 = (i32)0;
            ins.hItem = (pointer)0;
            ins.state = (u32)0;
            ins.stateMask = (u32)0;
            ins.pszText = (pointer)o.nativeItemValue(child, (i32)0);
            ins.cchTextMax = (i32)0;
            ins.iImage = (i32)0;
            ins.iSelectedImage = (i32)0;
            ins.cChildren = (i32)0;
            ins.lParam = child;
            pointer hChild = SendMessageA(tv, (u32)TVM_INSERTITEMA, (pointer)0, (pointer)&ins);
            if (o.nativeExpandable(child) != (i32)0)
                {
                self.treeFill(tv, o, child, hChild); // its children
                if (o.nativeIsItemExpanded(child) != (i32)0)
                    {
                    SendMessageA(tv, (u32)TVM_EXPAND, (pointer)TVE_EXPAND, hChild);
                    }
                }
            }
        }

    // Zero an LVITEM so only the fields we set carry meaning (comctl reads the whole struct).
    void lvitemInit(LVITEM* it)
        {
        it.mask = (u32)0;
        it.iItem = (i32)0;
        it.iSubItem = (i32)0;
        it.state = (u32)0;
        it.stateMask = (u32)0;
        it._pad0 = (i32)0;
        it.pszText = (pointer)0;
        it.cchTextMax = (i32)0;
        it.iImage = (i32)0;
        it.lParam = (pointer)0;
        it.iIndent = (i32)0;
        it._pad1 = (i32)0;
        }

    // 1 if the two NUL-terminated strings differ (so we only push the field buffer when it actually changed).
    i32 strdiff(u8* a, u8* b)
        {
        i32 i = (i32)0;
        while (a[i] != (u8)0 && b[i] != (u8)0)
            {
            if (a[i] != b[i])
                {
                return (i32)1;
                }
            i = i + (i32)1;
            }
        if (a[i] != b[i])
            {
            return (i32)1;
            }
        return (i32)0;
        }
    // Read a checkbox's / radio's checked state from its neutral peer widget.
    i32 toggleState(pointer peer, i32 k)
        {
        if (k == (i32)UXKindCheckbox)
            {
            UXCheckbox* cb = (UXCheckbox* ?)(Object*)peer;
            if (cb != (UXCheckbox*)0 && cb.isChecked())
                {
                return (i32)1;
                }
            }
        else
            {
            UXRadioButton* rb = (UXRadioButton* ?)(Object*)peer;
            if (rb != (UXRadioButton*)0 && rb.isSelected())
                {
                return (i32)1;
                }
            }
        return (i32)0;
        }

    // An EDIT changed: copy its text back into the neutral field's buffer (parked on the control's
    // userdata at creation).  Keeps UXTextField.text() truthful when the app reads it.
    void syncFieldFromControl(pointer ctrl)
        {
        W32Field* f = (W32Field*)GetWindowLongPtrA(ctrl, (i32)GWLP_USERDATA);
        if (f != (W32Field*)0)
            {
            GetWindowTextA(ctrl, (pointer)&f.buf[0], f.cap);
            }
        }
    // Walk the shadow tree; a custom view calls back into drawRect, a label paints its text.
    void drawOne(W32Tree* t, i32 i)
        {
        if (i < (i32)0 || t.nodes[i].hidden != (i16)0)
            {
            return;
            }
        i32 k = t.nodes[i].kind;
        // native trackbar/combo/updown/progress/toolbar/segmented paint themselves — don't self-draw under them
        if ((k == (i32)UXKindSlider || k == (i32)UXKindPopup || k == (i32)UXKindStepper || k == (i32)UXKindProgress || k == (i32)UXKindSegmented || k == (i32)UXKindToolbar || k == (i32)UXKindTextView) && t.nodes[i].ctrl != (pointer)0)
            {
            return;
            }
        // A GL view with an offscreen surface is PAINTED HERE: its last frame, blitted, in tree order,
        // so whatever comes after it in the tree is drawn over the map.
        if (k == (i32)UXKindGLView)
            {
            i32 gax = (i32)0;
            i32 gay = (i32)0;
            i32 gaw = (i32)0;
            i32 gah = (i32)0;
            self.structAbsFrame((pointer)t, i, &gax, &gay, &gaw, &gah);
            if (w32_gl_blit(t.nodes[i].peer, gax, gay, gaw, gah) != (i32)0)
                {
                return;
                }
            }
        // A SHIELD is app-drawn too: it intercepts input, it is not invisible.  A GL view is
        // here for the same reason: what it draws is its SOFTWARE FALLBACK, and once makeGL
        // has bound a context the neutral ux_userdraw declines to enter app code at all, so
        // the surface is the picture and this costs one virtual call.  A self-surface view is
        // here because Win32 makes no surface to hold its paint: it DECLINES, and drawing the
        // view inline as a UXKindView is exactly that decline.
        if ((k == (i32)UXKindView || k == (i32)UXKindShield || k == (i32)UXKindGLView || k == (i32)UXKindSurface) && gW32UserFn != (pointer)0)
            {
            // A view's drawing stays INSIDE ITS FRAME, as an NSView's does.
            if (gW32SaveDC == (pointer)0)
                {
                pointer gdi = LoadLibraryA((pointer)"gdi32.dll");
                if (gdi != (pointer)0)
                    {
                    gW32SaveDC = GetProcAddress(gdi, (u8*)"SaveDC");
                    gW32RestoreDC = GetProcAddress(gdi, (u8*)"RestoreDC");
                    gW32IntersectClip = GetProcAddress(gdi, (u8*)"IntersectClipRect");
                    }
                }
            i32 saved = (i32)0;
            if (gW32SaveDC != (pointer)0 && gW32RestoreDC != (pointer)0 && gW32IntersectClip != (pointer)0 && gW32CurHdc != (pointer)0)
                {
                i32 vx = (i32)0;
                i32 vy = (i32)0;
                i32 vw = (i32)0;
                i32 vh = (i32)0;
                self.structAbsFrame((pointer)t, i, &vx, &vy, &vw, &vh);
                vx = vx - gW32DrawOX;
                vy = vy - gW32DrawOY;
                W32SaveDCFn* sd = (W32SaveDCFn*)gW32SaveDC;
                saved = sd(gW32CurHdc);
                W32IntersectClipFn* ic = (W32IntersectClipFn*)gW32IntersectClip;
                ic(gW32CurHdc, vx, vy, vx + vw, vy + vh);
                }
            UXUserDrawFn* f = (UXUserDrawFn*)gW32UserFn;
            f((pointer)t.nodes, i, gW32UserUd);
            if (saved != (i32)0)
                {
                W32RestoreDCFn* rd = (W32RestoreDCFn*)gW32RestoreDC;
                rd(gW32CurHdc, saved);
                }
            }
        else if (k == (i32)UXKindButton && t.nodes[i].ctrl != (pointer)0)
            {
            // A native BUTTON control (realizeTree) paints itself — nothing to draw here.
            }
        else if (k == (i32)UXKindButton)
            {
            // Fallback stock button (no native control): a raised grey box with its title.
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 w = (i32)0;
            i32 hh = (i32)0;
            self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
            RECT rc;
            rc.left = ax;
            rc.top = ay;
            rc.right = ax + w;
            rc.bottom = ay + hh;
            pointer br = CreateSolidBrush((u32)$00C0C0C0);
            FillRect(gW32CurHdc, (pointer)&rc, br);
            DeleteObject(br);
            DrawEdge(gW32CurHdc, (pointer)&rc, (u32)EDGE_RAISED, (u32)BF_RECT); // the 3D Windows button
            if (t.nodes[i].spec != (pointer)0)
                {
                SetBkMode(gW32CurHdc, (i32)TRANSPARENT);
                SetTextColor(gW32CurHdc, t.nodes[i].enabled != (i16)0 ? (u32)0 : (u32)$00808080); // grey if disabled
                w32DrawText(gW32CurHdc, ax + (i32)6, ay + (i32)4, (u8*)t.nodes[i].spec);
                }
            }
        else if (k == (i32)UXKindField && t.nodes[i].ctrl != (pointer)0)
            {
            // A native EDIT control paints itself — nothing to draw here.
            }
        else if (k == (i32)UXKindField)
            {
            // Fallback field (no native control): a white sunken box with the editor's text.
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 w = (i32)0;
            i32 hh = (i32)0;
            self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
            RECT rc;
            rc.left = ax;
            rc.top = ay;
            rc.right = ax + w;
            rc.bottom = ay + hh;
            pointer br = CreateSolidBrush((u32)$00FFFFFF);
            FillRect(gW32CurHdc, (pointer)&rc, br);
            DeleteObject(br);
            DrawEdge(gW32CurHdc, (pointer)&rc, (u32)EDGE_SUNKEN, (u32)BF_RECT); // the sunken Windows field
            W32Field* f = (W32Field*)t.nodes[i].spec;
            if (f != (W32Field*)0 && f.buf[0] != (u8)0)
                {
                SetBkMode(gW32CurHdc, (i32)TRANSPARENT);
                SetTextColor(gW32CurHdc, (u32)0);
                w32DrawText(gW32CurHdc, ax + (i32)4, ay + (i32)3, (u8*)&f.buf[0]);
                }
            }
        else if (k == (i32)UXKindScroll && t.nodes[i].ctrl != (pointer)0)
            {
            return; // a native WS_VSCROLL child paints its own subtree (offset) — don't recurse here
            }
        else if (k == (i32)UXKindTable && t.nodes[i].ctrl != (pointer)0)
            {
            return; // a native SysListView32 paints itself AND its rows — don't draw the box or recurse
            }
        else if (k == (i32)UXKindTable)
            {
            // Fallback list box (no native ListView): a WHITE sunken area drawn under the row subtree.
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 w = (i32)0;
            i32 hh = (i32)0;
            self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
            RECT rc;
            rc.left = ax;
            rc.top = ay;
            rc.right = ax + w;
            rc.bottom = ay + hh;
            pointer br = CreateSolidBrush((u32)$00FFFFFF);
            FillRect(gW32CurHdc, (pointer)&rc, br);
            DeleteObject(br);
            DrawEdge(gW32CurHdc, (pointer)&rc, (u32)EDGE_SUNKEN, (u32)BF_RECT);
            }
        else if (k == (i32)UXKindLabel && t.nodes[i].spec != (pointer)0)
            {
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 w = (i32)0;
            i32 hh = (i32)0;
            self.structAbsFrame((pointer)t, i, &ax, &ay, &w, &hh);
            SetBkMode(gW32CurHdc, (i32)TRANSPARENT);
            SetTextColor(gW32CurHdc, (u32)0);
            w32DrawText(gW32CurHdc, ax + (i32)2, ay + (i32)2, (u8*)t.nodes[i].spec);
            }
        i16 c = t.nodes[i].head;
        while (c >= (i16)0)
            {
            self.drawOne(t, (i32)c);
            c = t.nodes[c].next;
            }
        }
    void treeDraw(pointer tree, i32 start, i32 clx, i32 cly, i32 clw, i32 clh)
        {
        gW32DrawTree = (W32Tree*)tree;
        self.drawOne((W32Tree*)tree, start);
        }
    // the view is clipped to its frame by this driver's own tree walk
    void endViewDraw(void)
        {
        }
    UXGraphics* beginViewDraw(i32 ax, i32 ay, i32 aw, i32 ah)
        {
        gW32Gfx.bind(gW32CurHdc, UXGeom.make((i16)(ax - gW32DrawOX), (i16)(ay - gW32DrawOY), (i16)aw, (i16)ah));
        return gW32Gfx;
        }
    void setDrawOffset(i32 x, i32 y)
        {
        gW32DrawOX = x;
        gW32DrawOY = y;
        }
    // a WS_VSCROLL child owns the offset
    bool scrollsNatively(void)
        {
        return true;
        }

    // ---- text editing --------------------------------------------------------
    // GEM hands this to objc_edit; here the driver is the edit engine.  Small on purpose:
    // insert a printable char, Backspace, and carry the caret in/out — the field's whole job.
    pointer fieldEditorNew(u8* buf, i32 cap)
        {
        W32Field* f = (W32Field*)malloc((u32)sizeof(W32Field));
        f.buf = buf;
        f.cap = cap;
        f.valid = (u8*)0;
        f.field = (pointer)0;
        f.place = (u8*)0;
        f.secure = (i32)0;
        return (pointer)f;
        }
    void fieldEditorSetValid(pointer ed, u8* valid)
        {
        ((W32Field*)ed).valid = valid;
        }
    void fieldEditorSetPlaceholder(pointer ed, u8* s)
        {
        ((W32Field*)ed).place = s;
        }
    void fieldEditorSetSecure(pointer ed, i32 on)
        {
        ((W32Field*)ed).secure = on;
        }
    void fieldEditorFree(pointer ed)
        {
        if (ed != (pointer)0)
            {
            free(ed);
            }
        }

    // A validation code (the char at the caret's position in the validation string) vs a typed
    // char: '9' digit, 'A' upper+space, 'a' letters, 'X'/unknown anything.  Same alphabet GEM's
    // edit engine enforces (UXTextField.setValidation).
    bool validOk(u8 code, i32 ch)
        {
        // '9'
        if (code == (u8)57)
            {
            return ch >= (i32)48 && ch <= (i32)57;
            }
        // 'A'
        if (code == (u8)65)
            {
            return (ch >= (i32)65 && ch <= (i32)90) || ch == (i32)32;
            }
        // 'a'
        if (code == (u8)97)
            {
            return (ch >= (i32)97 && ch <= (i32)122) || (ch >= (i32)65 && ch <= (i32)90);
            }
        return true; // 'X' / anything
        }

    i32 editText(pointer tree, i32 obj, i32 key, i32* caret, i32 mode)
        {
        W32Field* f = (W32Field*)((W32Tree*)tree).nodes[obj].spec;
        if (f == (W32Field*)0)
            {
            return (i32)0;
            }
        u8* b = f.buf;
        i32 len = (i32)0;
        while (b[len] != (u8)0)
            {
            len = len + (i32)1;
            }
        i32 c = caret[0];
        if (c < (i32)0)
            {
            c = (i32)0;
            }
        if (c > len)
            {
            c = len;
            }

        if (mode == (i32)UXEditBegin || mode == (i32)UXEditEnd)
            {
            caret[0] = len;
            return (i32)1;
            }

        i32 ch = key & (i32)$FF; // the ASCII byte (see UXEvent)
        // Backspace
        if (ch == (i32)8)
            {
            if (c == (i32)0)
                {
                return (i32)1;
                }
            for (i32 i = c - (i32)1; i < len; i = i + (i32)1)
                {
                b[i] = b[i + (i32)1];
                }
            caret[0] = c - (i32)1;
            return (i32)1;
            }
        // a printable char, inserted at the caret
        if (ch >= (i32)32 && ch < (i32)127)
            {
            // full: consume, don't overflow
            if (len >= f.cap - (i32)1)
                {
                return (i32)1;
                }
            // per-position validation, if set
            if (f.valid != (u8*)0)
                {
                i32 vn = (i32)0;
                while (f.valid[vn] != (u8)0)
                    {
                    vn = vn + (i32)1;
                    }
                // reject: consume, no insert
                if (c < vn && !self.validOk(f.valid[c], ch))
                    {
                    return (i32)1;
                    }
                }
            for (i32 i = len; i > c; i = i - (i32)1)
                {
                b[i] = b[i - (i32)1];
                }
            b[c] = (u8)ch;
            b[len + (i32)1] = (u8)0;
            caret[0] = c + (i32)1;
            return (i32)1;
            }
        return (i32)0; // Tab/Return/etc. -> climb the chain
        }

    // ---- menus ---------------------------------------------------------------
    // The neutral model is app-level (one UXMenuBar); Win32 has no screen bar, so the driver
    // realizes it as a per-window HMENU on EVERY window (windowCreate attaches it too, so a
    // window opened after the menu still gets it).  A menu item fires WM_COMMAND(id); the id
    // encodes (title, item) ordinals directly, so menuItemOrd is the identity and the neutral
    // UXMenuBar.handleSelection routes it with no GEM-shaped remapping.
    i32 menuId(i32 titleOrd, i32 itemOrd)
        {
        return titleOrd * (i32)256 + itemOrd + (i32)1;
        }

    pointer menuBuild(pointer defs, i32 n, i32 screenW)
        {
        UXMenuDef* d = (UXMenuDef*)defs;
        pointer bar = CreateMenu();
        for (i32 t = (i32)0; t < n; t = t + (i32)1)
            {
            pointer sub = CreatePopupMenu();
            u8** items = d[t].items;
            for (i32 j = (i32)0; j < d[t].nitems; j = j + (i32)1)
                {
                u8* s = items[j];
                // "-" : a separator
                if (s[0] == (u8)45 && s[1] == (u8)0)
                    {
                    AppendMenuA(sub, (u32)MF_SEPARATOR, (pointer)0, (pointer)0);
                    }
                else
                    {
                    u32 flags = (u32)MF_STRING;
                    u8* text = s;
                    // pre-ticked
                    if (s[0] == (u8)1)
                        {
                        flags = flags | (u32)MF_CHECKED;
                        text = &s[1];
                        }
                    // disabled
                    else if (s[0] == (u8)2)
                        {
                        flags = flags | (u32)MF_GRAYED;
                        text = &s[1];
                        }
                    // a shortcut is spelled out after a tab, which Windows right-aligns
                    AppendMenuA(sub, flags, (pointer)self.menuId(t, j), (pointer)UXMenuKey.labelled(text, (u8*)"\t", (u8*)"Ctrl+", (u8*)"Shift+"));
                    }
                }
            AppendMenuA(bar, (u32)MF_POPUP, sub, (pointer)d[t].title);
            }
        return bar;
        }
    void menuShow(pointer menu, i32 show)
        {
        gW32Menu = show != (i32)0 ? menu : (pointer)0;
        // attach to every live window
        for (i32 i = (i32)1; i < gW32NextHandle; i = i + (i32)1)
            {
            if (gW32Hwnds[i] != (pointer)0)
                {
                SetMenu(gW32Hwnds[i], gW32Menu);
                DrawMenuBar(gW32Hwnds[i]);
                }
            }
        }
    // ids ARE ordinals
    i32 menuItemOrd(pointer menu, i32 titleOrd, i32 itemObj)
        {
        return itemObj;
        }
    void menuCheck(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        CheckMenuItem(menu, (u32)self.menuId(titleOrd, itemOrd),
                      (u32)MF_BYCOMMAND | (on != (i32)0 ? (u32)MF_CHECKED : (u32)MF_UNCHECKED));
        }
    void menuEnable(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
        {
        EnableMenuItem(menu, (u32)self.menuId(titleOrd, itemOrd),
                       (u32)MF_BYCOMMAND | (on != (i32)0 ? (u32)MF_ENABLED : (u32)MF_GRAYED));
        }

    // ---- events (message pump) -----------------------------------------------
    // Is this HWND one of our top-level windows (its own canvas), rather than a native child control?
    i32 isUXWindow(pointer hwnd)
        {
        return self.handleOf(hwnd) != (i32)0 ? (i32)1 : (i32)0;
        }
    // Does this HWND's window class name the standard single-line edit control?  The class is
    // spelled "Edit", not "EDIT": the API that REGISTERS it (CreateWindowExA) takes the name
    // case-insensitively, which is how comparing GetClassNameA's answer against "EDIT" looks right
    // and matches nothing.  Fold the four letters to upper case first.
    i32 isEditClass(pointer hwnd)
        {
        u8 cn[16];
        if (GetClassNameA(hwnd, (pointer)&cn[0], (i32)16) <= (i32)0)
            {
            return (i32)0;
            }
        if (cn[0] == (u8)'e') { cn[0] = (u8)'E'; }
        if (cn[1] == (u8)'d') { cn[1] = (u8)'D'; }
        if (cn[2] == (u8)'i') { cn[2] = (u8)'I'; }
        if (cn[3] == (u8)'t') { cn[3] = (u8)'T'; }
        return (cn[0] == (u8)'E' && cn[1] == (u8)'D' && cn[2] == (u8)'I' && cn[3] == (u8)'T' && cn[4] == (u8)0)
                   ? (i32)1
                   : (i32)0;
        }
    i32 handleOf(pointer hwnd)
        {
        for (i32 i = (i32)1; i < gW32NextHandle; i = i + (i32)1)
            {
            if (gW32Hwnds[i] == hwnd)
                {
                return i;
                }
            }
        return (i32)0;
        }
    void nextEvent(i32 timeoutMs, UXEvent* ev)
        {
        ev.kind = (u8)UXEventNone;
        ev.handle = (i32)0;
        MSG msg;
        // With a frame clock the wait must END on its own: wait for input OR the deadline, and
        // return an empty turn when the deadline beats it.  GetMessageA (below) blocks until there
        // IS a message, which would keep the app's turn from ever arriving.  A zero timeout keeps
        // the old block-until-there-is-one behaviour, so nothing changes for a client without a
        // clock.
        if (timeoutMs > (i32)0)
            {
            if (MsgWaitForMultipleObjects((u32)0, (pointer)0, (i32)0, (u32)timeoutMs, (u32)QS_ALLINPUT) == (u32)WAIT_TIMEOUT)
                {
                return; // empty turn: the clock fired, no input
                }
            if (PeekMessageA((pointer)&msg, (pointer)0, (u32)0, (u32)0, (u32)PM_REMOVE) == (i32)0)
                {
                return; // a message was consumed by another thread's pump; turn is empty
                }
            }
        else
            {
            if (GetMessageA((pointer)&msg, (pointer)0, (u32)0, (u32)0) <= (i32)0)
                {
                ev.kind = (u8)UXEventClose;
                return; // WM_QUIT -> stop the loop
                }
            }
        // A click or keystroke aimed at a native CHILD control belongs to the OS: it must be
        // dispatched so the button fires (-> WM_COMMAND) and the EDIT focuses + edits.  ONLY the
        // window's own canvas (custom-drawn views: the backdrop, the table) is neutral hit-tested.
        i32 onWindow = self.isUXWindow(msg.hwnd);
        if (msg.message == (u32)WM_LBUTTONDOWN && onWindow != (i32)0)
            {
            u32 lpw = (u32)msg.lParam;
            // lParam is CLIENT coords — window-local, so they can't identify which window was clicked.
            // Tag the event with the clicked window's handle so dispatch routes to the right tree.
            ev.kind = (u8)UXEventMouseDown;
            ev.x = (i16)lpw;
            ev.y = (i16)(lpw >> (u32)16);
            ev.handle = self.handleOf(msg.hwnd);
            return;
            }
        // Pointer movement and the secondary button: client coords in lParam, tagged like the click.
        if (msg.message == (u32)WM_MOUSEMOVE && onWindow != (i32)0)
            {
            u32 lpw = (u32)msg.lParam;
            ev.kind = (u8)UXEventMouseMoved;
            ev.x = (i16)lpw;
            ev.y = (i16)(lpw >> (u32)16);
            ev.handle = self.handleOf(msg.hwnd);
            return;
            }
        if (msg.message == (u32)WM_RBUTTONDOWN && onWindow != (i32)0)
            {
            u32 lpw = (u32)msg.lParam;
            ev.kind = (u8)UXEventRightMouseDown;
            ev.x = (i16)lpw;
            ev.y = (i16)(lpw >> (u32)16);
            ev.handle = self.handleOf(msg.hwnd);
            return;
            }
        if (msg.message == (u32)WM_MOUSEWHEEL && onWindow != (i32)0)
            {
            // The wheel's delta is the signed HIWORD of wParam in WHEEL_DELTA (120) units, and its
            // point is in SCREEN coords, so convert it to this window's client coords first.
            i32 delta = (i32)((i16)((u32)msg.wParam >> (u32)16));
            POINT pt;
            pt.x = (i32)(i16)((u32)msg.lParam & (u32)$FFFF);
            pt.y = (i32)(i16)((u32)msg.lParam >> (u32)16);
            ScreenToClient(msg.hwnd, (pointer)&pt);
            ev.kind = (u8)UXEventWheel;
            ev.x = (i16)pt.x;
            ev.y = (i16)pt.y;
            ev.a = delta / (i32)WHEEL_DELTA;                       // notches, positive up
            ev.b = (i32)0 - (delta * (i32)100) / (i32)WHEEL_DELTA; // the DOM's deltaY: 100 a click, down +
            ev.handle = self.handleOf(msg.hwnd);
            return;
            }
        if (msg.message == (u32)WM_CHAR && onWindow != (i32)0)
            {
            ev.kind = (u8)UXEventKeyDown;
            ev.key = (u16)((u32)msg.wParam & (u32)$FF); // ASCII byte
            // Control and Shift, as GEM's kstate has them, so a menu shortcut can be matched
            u16 mods = (u16)0;
            if ((i32)GetKeyState((i32)$11) < (i32)0) // VK_CONTROL
                {
                mods = mods | (u16)UX_MOD_CTRL;
                }
            if ((i32)GetKeyState((i32)$10) < (i32)0) // VK_SHIFT
                {
                mods = mods | (u16)1;
                }
            ev.modifiers = mods;
            return;
            }
        // A text view's RichEdit: Control-Z, Shift-Control-Z and Control-Y are the view's undo (the
        // RichEdit's own is off), and a click, a drag or a moving key is the user moving the selection
        // (a move that typing makes is not, so a run of typing stays one undo step).
        if (onWindow == (i32)0 && (msg.message == (u32)WM_KEYDOWN || msg.message == (u32)WM_LBUTTONDOWN ||
                                   msg.message == (u32)WM_MOUSEMOVE))
            {
            W32TextView* ktv = W32TextView.of(msg.hwnd);
            if (ktv != (W32TextView*)0)
                {
                if (msg.message == (u32)WM_KEYDOWN && (i32)GetKeyState((i32)$11) < (i32)0 &&
                    ((u32)msg.wParam == (u32)$5A || (u32)msg.wParam == (u32)$59))
                    {
                    bool redo = (u32)msg.wParam == (u32)$59 || (i32)GetKeyState((i32)$10) < (i32)0;
                    ktv.undoKey(redo);
                    return; // consumed: not the RichEdit's
                    }
                if (msg.message == (u32)WM_LBUTTONDOWN || (msg.message == (u32)WM_MOUSEMOVE && ((u32)msg.wParam & (u32)1) != (u32)0) ||
                    (msg.message == (u32)WM_KEYDOWN && (u32)msg.wParam >= (u32)$21 && (u32)msg.wParam <= (u32)$28))
                    {
                    ktv.userMoved = true; // PageUp..Down, End, Home, the arrows
                    }
                }
            }
        // Return aimed at a native EDIT child: a single-line EDIT DISCARDS the key (and beeps),
        // so the field's onSubmit would never fire from a real keystroke -- only from the
        // synthetic WM_CHAR path above.  The class name is checked before the userdata is read as a
        // W32Field, because a BUTTON's userdata is an UXControl and reading the wrong one is how
        // the EN_CHANGE comment below says this crashes.
        if (msg.message == (u32)WM_KEYDOWN && onWindow == (i32)0 && (u32)msg.wParam == (u32)VK_RETURN
            && self.isEditClass(msg.hwnd) != (i32)0)
            {
            W32Field* wf = (W32Field*)GetWindowLongPtrA(msg.hwnd, (i32)GWLP_USERDATA);
            if (wf != (W32Field*)0 && wf.field != (pointer)0)
                {
                ((UXTextField*)wf.field).fieldDidSubmit();
                if (gApp != (UXApplication*)0)
                    {
                    gApp.displayIfNeeded(); // a submit may change what the app draws
                    }
                return; // consumed: the field owns its Return
                }
            }
        if (msg.message == (u32)WM_CLOSE && onWindow != (i32)0)
            {
            // The close box: hand the app a tagged close for THIS window (don't DispatchMessage, so
            // DefWindowProc doesn't DestroyWindow behind our back) — closeWindow destroys it and quits
            // only if it was the last.
            ev.kind = (u8)UXEventClose;
            ev.handle = self.handleOf(msg.hwnd);
            return;
            }
        if (msg.message == (u32)WM_SIZE && onWindow != (i32)0)
            {
            // Let the toolkit reflow (springs & struts): it re-lays the tree into the new work area
            // and realizeTree repositions the native controls.  CS_H/VREDRAW already forces the repaint.
            i32 handle = self.handleOf(msg.hwnd);
            gW32WinW[handle] = (i32)((u32)msg.lParam & (u32)$FFFF);
            gW32WinH[handle] = (i32)(((u32)msg.lParam >> (u32)16) & (u32)$FFFF);
            ev.kind = (u8)UXEventResize;
            ev.handle = handle;
            return;
            }
        if (msg.message == (u32)WM_COMMAND && msg.lParam == (pointer)0)
            {
            i32 id = (i32)((u32)msg.wParam & (u32)$FFFF); // LOWORD(wParam) = menu-item id
            // (A control's WM_COMMAND is SENT to the proc, not queued here — see UXWin32Proc.)
            // a menu-item id
            if (id != (i32)0)
                {
                i32 idx = id - (i32)1;
                ev.kind = (u8)UXEventMenuSelect;
                ev.a = (idx / (i32)256) + (i32)2; // handleSelection subtracts 2 for the title
                ev.b = idx % (i32)256;            // the item ordinal
                return;
                }
            }
        TranslateMessage((pointer)&msg);
        DispatchMessageA((pointer)&msg); // WM_PAINT etc.
        }
    void pumpMessages(i32 timeoutMs, UXEvent* ev)
        {
        ev.kind = (u8)UXEventNone;
        MSG msg;
        if (PeekMessageA((pointer)&msg, (pointer)0, (u32)0, (u32)0, (u32)PM_REMOVE) != (i32)0)
            {
            TranslateMessage((pointer)&msg);
            DispatchMessageA((pointer)&msg);
            }
        }

    // A modal alert via MessageBox.  It shows OK/Cancel/Yes/No (not the neutral labels — Win32
    // has no arbitrary-button box), but the RESULT maps back to the neutral 1-based index, which
    // is what the app reads.  A '|' in the lines becomes a newline for the body text.
    i32 alertRun(i32 icon, u8* lines, u8* buttons, i32 defaultBtn)
        {
        // count neutral buttons (pipe-separated); build the newline-joined body in a scratch buf
        i32 nb = (i32)1;
            {
            i32 i = (i32)0;
            while (buttons[i] != (u8)0)
                {
                if (buttons[i] == (u8)124)
                    {
                    nb = nb + (i32)1;
                    }
                i = i + (i32)1;
                }
            }
        u8 body[512];
        i32 bn = (i32)0;
            {
            i32 i = (i32)0;
            while (lines[i] != (u8)0 && bn < (i32)510)
                {
                body[bn] = lines[i] == (u8)124 ? (u8)10 : lines[i];
                bn = bn + (i32)1;
                i = i + (i32)1;
                }
            }
        body[bn] = (u8)0;

        u32 type = nb >= (i32)3 ? (u32)MB_YESNOCANCEL : (nb == (i32)2 ? (u32)MB_OKCANCEL : (u32)MB_OK);
        type = type | (icon >= (i32)3 ? (u32)MB_ICONSTOP : (u32)MB_ICONINFO);
        i32 r = MessageBoxA((pointer)0, (u8*)&body[0], (u8*)"Alert", type);

        if (nb >= (i32)3)
            {
            return r == (i32)IDYES ? (i32)1 : (r == (i32)IDNO ? (i32)2 : (i32)3);
            }
        if (nb == (i32)2)
            {
            return r == (i32)IDOK ? (i32)1 : (i32)2;
            }
        return (i32)1;
        }

    i32 liveNativeCount(void)
        {
        return gW32Native;
        }
    // ---- GL ------------------------------------------------------------------
    // The surface is described above UXGl32Proc; these are the protocol's half of it.
    // glKind is a property of the BACKEND and not of a context, so it answers before
    // anything is made: this backend can offer a GL 3.3 core context, and a machine whose
    // driver refuses one gets a compatibility context instead, which compiles the same
    // GLSL ES 3.00 source.  If even that fails, makeGLContext returns 0 and the view
    // falls back to drawRect, which is the software path the gates run.
    i32 glKind(void)
        {
        return (i32)UX_GL_GL33;
        }
    // No GL plane: the frame is rendered offscreen and blitted in the window's own paint, ordered with
    // the 2-D views by tree order.  (A GL with no framebuffer objects falls back to a visible child.)
    bool compositesWithGL(void)
        {
        return false;
        }

    pointer glProc(u8* name)
        {
        w32_gl_load();
        if (gW32GlLib == (pointer)0)
            {
            return (pointer)0;
            }
        if (gW32WglGetProc != (pointer)0)
            {
            WglGetProcFn* g = (WglGetProcFn*)gW32WglGetProc;
            pointer p = g(name);
            if (p != (pointer)0)
                {
                return p;
                }
            }
        return GetProcAddress(gW32GlLib, name);
        }

    pointer makeGLContext(pointer view)
        {
        i32 i = w32_gl_find(view);
        if (i < (i32)0)
            {
            return (pointer)0; // no surface (unrealized, or the library would not open)
            }
        if (gW32GlCtx[i] == (pointer)0)
            {
            // Ask for a core profile first.  wglCreateContextAttribsARB is an EXTENSION, so
            // it is reached through wglGetProcAddress and may not be there at all.
            if (gW32WglCreateAttribs != (pointer)0)
                {
                i32 attribs[7];
                attribs[0] = (i32)WGL_CONTEXT_MAJOR_VERSION_ARB;
                attribs[1] = (i32)3;
                attribs[2] = (i32)WGL_CONTEXT_MINOR_VERSION_ARB;
                attribs[3] = (i32)3;
                attribs[4] = (i32)WGL_CONTEXT_PROFILE_MASK_ARB;
                attribs[5] = (i32)WGL_CONTEXT_CORE_PROFILE_BIT_ARB;
                attribs[6] = (i32)0;
                WglCreateAttribsFn* f = (WglCreateAttribsFn*)gW32WglCreateAttribs;
                gW32GlCtx[i] = f(gW32GlDc[i], (pointer)0, &attribs[0]);
                }
            if (gW32GlCtx[i] == (pointer)0 && gW32WglCreate != (pointer)0)
                {
                WglCreateFn* f = (WglCreateFn*)gW32WglCreate;
                gW32GlCtx[i] = f(gW32GlDc[i]);
                }
            if (gW32GlCtx[i] == (pointer)0)
                {
                return (pointer)0;
                }
            }
        if (gW32WglMakeCur == (pointer)0)
            {
            return (pointer)0;
            }
        WglMakeCurFn* mc = (WglMakeCurFn*)gW32WglMakeCur;
        if (mc(gW32GlDc[i], gW32GlCtx[i]) == (pointer)0)
            {
            return (pointer)0;
            }
        // The context is current on the calling thread, exactly as the seam promises, and
        // the pacing and the viewport are set in this same turn.
        if (gW32WglSwapInterval != (pointer)0)
            {
            WglSwapIntervalFn* si = (WglSwapIntervalFn*)gW32WglSwapInterval;
            si(gW32GlSwap > (i32)0 ? (i32)1 : (i32)0);
            }
        w32_gl_viewport(view);
        if (gW32GlOff[i] == (i32)0 && w32_gl_offscreen(i) != (i32)0)
            {
            gW32GlOff[i] = (i32)1;
            ShowWindow(gW32GlHwnd[i], (i32)0); // the paint blits the frame; the child must not clip it
            }
        return (pointer)(i + (i32)1); // the opaque token, never the context
        }

    void destroyGLContext(pointer view)
        {
        i32 i = w32_gl_find(view);
        if (i < (i32)0 || gW32GlCtx[i] == (pointer)0)
            {
            return;
            }
        if (gW32WglMakeCur != (pointer)0)
            {
            WglMakeCurFn* mc = (WglMakeCurFn*)gW32WglMakeCur;
            mc((pointer)0, (pointer)0); // unbind first: a context deleted while current leaks
            }
        if (gW32WglDeleteCtx != (pointer)0)
            {
            WglDeleteCtxFn* d = (WglDeleteCtxFn*)gW32WglDeleteCtx;
            d(gW32GlCtx[i]);
            }
        gW32GlCtx[i] = (pointer)0;
        w32_gl_free_offscreen(i);
        gW32GlOff[i] = (i32)0;
        }

    void resizeGL(pointer view, i32 w, i32 h)
        {
        // The child window is moved by the tree (structSetFrame), which is the same turn;
        // what is left for the driver is the drawable's pixel size.
        w32_gl_viewport(view);
        }

    // The frame is finished.  Offscreen: read it back into the DIB and invalidate the window, so the
    // next paint blits it in tree order -- and remake the framebuffer if the view changed size, for
    // the NEXT frame.  On the visible plane (no framebuffer objects): the swap.
    void presentGL(pointer view)
        {
        i32 i = w32_gl_find(view);
        if (i < (i32)0 || gW32GlCtx[i] == (pointer)0)
            {
            return;
            }
        if (gW32GlOff[i] == (i32)0)
            {
            SwapBuffers(gW32GlDc[i]);
            return;
            }
        WglMakeCurFn* mc = (WglMakeCurFn*)gW32WglMakeCur;
        mc(gW32GlDc[i], gW32GlCtx[i]);
        W32GlBindFn* bind = (W32GlBindFn*)gW32BindFb;
        bind((u32)$8D40, gW32GlFbo[i]);
        W32GlReadPixelsFn* rp = (W32GlReadPixelsFn*)gW32ReadPx;
        rp((i32)0, (i32)0, gW32GlPW[i], gW32GlPH[i], (u32)$80E1, (u32)$1401, gW32GlPx[i]); // GL_BGRA, UNSIGNED_BYTE
        pointer parent = GetParent(gW32GlHwnd[i]);
        if (parent != (pointer)0)
            {
            InvalidateRect(parent, (pointer)0, (i32)0);
            }
        w32_gl_offscreen(i); // the next frame at the view's current size
        w32_gl_viewport(view);
        }

    void glSetSwapInterval(i32 interval)
        {
        gW32GlSwap = interval;
        if (gW32WglSwapInterval == (pointer)0 || gW32WglMakeCur == (pointer)0)
            {
            return;
            }
        WglSwapIntervalFn* si = (WglSwapIntervalFn*)gW32WglSwapInterval;
        WglMakeCurFn* mc = (WglMakeCurFn*)gW32WglMakeCur;
        for (i32 i = (i32)0; i < gW32GlCount; i = i + (i32)1)
            {
            if (gW32GlCtx[i] != (pointer)0 && mc(gW32GlDc[i], gW32GlCtx[i]) != (pointer)0)
                {
                si(interval > (i32)0 ? (i32)1 : (i32)0);
                }
            }
        }
    // a GL view's drawable and its last frame: the frame each present reads back (gW32GlPx, BGRA,
    // bottom-up) for the paint pass
    i32 w32GlFind(pointer view)
        {
        for (i32 k = (i32)0; k < gW32GlCount; k = k + (i32)1)
            {
            if (gW32GlPeer[k] == view)
                {
                return k;
                }
            }
        return (i32)-1;
        }
    i32 glDrawableSize(pointer view, i32* pw, i32* ph)
        {
        i32 k = self.w32GlFind(view);
        if (k < (i32)0 || gW32GlPW[k] <= (i32)0 || gW32GlPH[k] <= (i32)0)
            {
            return (i32)0;
            }
        pw[0] = gW32GlPW[k];
        ph[0] = gW32GlPH[k];
        return (i32)1;
        }
    i32 glReadFrame(pointer view, u32* out, i32 pw, i32 ph)
        {
        i32 k = self.w32GlFind(view);
        if (k < (i32)0 || gW32GlPx[k] == (pointer)0 || gW32GlPW[k] != pw || gW32GlPH[k] != ph)
            {
            return (i32)0;
            }
        u8* src = (u8*)gW32GlPx[k];
        for (i32 y = (i32)0; y < ph; y = y + (i32)1)
            {
            u8* r = src + (ph - (i32)1 - y) * pw * (i32)4; // bottom-up -> top-down
            for (i32 x = (i32)0; x < pw; x = x + (i32)1)
                {
                u8* q = r + x * (i32)4; // B G R A
                out[y * pw + x] = ((u32)q[3] << (u32)24) | ((u32)q[2] << (u32)16) | ((u32)q[1] << (u32)8) | (u32)q[0];
                }
            }
        return (i32)1;
        }

    // The frame clock: the neutral loop calls fn, and its wait is honoured by nextEvent (a
    // timed wait on the message queue).  The driver does not own the loop, so it answers
    // false and lets UXApplication pace itself.
    bool setTurnHook(turnHook_t* fn, i32 ms)
        {
        return false;
        }

    i32 formFactorClass(void)
        {
        return (i32)UX_FORM_DESKTOP;
        }
    // the desktop has no orientation axis
    i32 orientation(void)
        {
        return (i32)UX_ORIENT_NONE;
        }
    bool driverOwnsRunLoop(void)
        {
        return false;
        }

    // the application's lifecycle (UXViewDriver): nothing to wire, stop or hide here
    void appAttached(pointer app)
        {
        }
    void requestStop(void)
        {
        }
    void setHeadless(bool on)
        {
        }
    bool stopAfterMs(i32 ms)
        {
        return false;
        }
    void runLoop(void)
        {
        }

    // ---- Win32-specific support (not part of UXViewDriver) --------------------
    // The native HWND behind a handle.  Lets a Win32 program (or a test simulating the OS)
    // reach the window to PostMessage into the real event queue — the neutral run loop then
    // pumps it through nextEvent like any other input.
    pointer windowNative(i32 handle)
        {
        return gW32Hwnds[handle];
        }
    }
