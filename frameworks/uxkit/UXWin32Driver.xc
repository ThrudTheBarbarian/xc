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
    UXControl* c = (UXControl* ?)GetWindowLongPtrA(ctrl, (i32)GWLP_USERDATA);
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

// The scroll-child window proc: WS_VSCROLL owns the bar; WM_PAINT draws the peer UXScrollView's
// DOCUMENT subtree offset by the scroll position, into this child's client (its own 0,0).
pointer UXScroll32Proc(pointer hwnd, u32 msg, pointer wp, pointer lp)
    {
    if (msg == (u32)WM_PAINT)
        {
        PAINTSTRUCT ps;
        pointer hdc = BeginPaint(hwnd, (pointer)&ps);
        SelectObject(hdc, gW32Font);
        RECT rc;
        GetClientRect(hwnd, (pointer)&rc);
        FillRect(hdc, (pointer)&rc, gW32FaceBrush); // clear the exposed area
        UXScrollView* sv = (UXScrollView* ?)GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA);
        if (sv != (UXScrollView*)0)
            {
            i32 pos = GetScrollPos(hwnd, (i32)SB_VERT);
            UXRect svAbs = sv.absoluteFrame(); // the child's position in the parent window
            gW32CurHdc = hdc;
            // abs -> child-client, scrolled: a view at (vx,vy) draws at (vx-svAbs.x, vy-svAbs.y-pos).
            gDriver.setDrawOffset((i32)svAbs.x, (i32)svAbs.y + pos);
            gDriver.treeSetUserDraw((pointer)&ux_scroll_userdraw, (pointer)sv.owner);
            gDriver.treeDraw((pointer)sv.owner.objects(), sv.nativeDocNode(),
                             (i32)0, (i32)0, (i32)(rc.right - rc.left), (i32)(rc.bottom - rc.top));
            gDriver.setDrawOffset((i32)0, (i32)0);
            }
        EndPaint(hwnd, (pointer)&ps);
        return (pointer)0;
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
        InvalidateRect(hwnd, (pointer)0, (i32)1);
        return (pointer)0;
        }
    // A click lands on THIS child, not the canvas, so nextEvent never sees it and the subtree the
    // container paints (a self-drawn list) could not be clicked.  Undo the paint transform — child
    // client -> the parent's client, the space the shadow tree's absolute frames live in — and post
    // it to the parent, where the toolkit's normal dispatchMouse hit-tests it like any other click.
    // Posted input outranks WM_PAINT, so invalidating now repaints AFTER the click has been handled.
    if (msg == (u32)WM_LBUTTONDOWN)
        {
        UXScrollView* sv = (UXScrollView* ?)GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA);
        pointer par = GetParent(hwnd);
        if (sv != (UXScrollView*)0 && par != (pointer)0)
            {
            u32 lpw = (u32)lp;
            UXRect svAbs = sv.absoluteFrame();
            i32 x = (i32)(i16)lpw + (i32)svAbs.x;
            i32 y = (i32)(i16)(lpw >> (u32)16) + (i32)svAbs.y + GetScrollPos(hwnd, (i32)SB_VERT);
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
        InvalidateRect(hwnd, (pointer)0, (i32)1);
        return (pointer)0;
        }
    return DefWindowProcA(hwnd, msg, wp, lp);
    }

// ── the window proc: the driver ─────────────────────────────────────────────
// WM_PAINT flows backend -> the neutral content callback -> treeDraw -> drawRect.
pointer UXWin32Proc(pointer hwnd, u32 msg, pointer wp, pointer lp)
    {
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
        UXControl* pc = (UXControl* ?)GetWindowLongPtrA(lp, (i32)GWLP_USERDATA);
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
                UXControl* ctl = (UXControl* ?)GetWindowLongPtrA(lp, (i32)GWLP_USERDATA);
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
        if (nh.code == (u32)LVN_ITEMCHANGED)
            {
            // our own write echoing back
            if (gW32SelPush != (i32)0)
                {
                return (pointer)0;
                }
            UXTableView* tv = (UXTableView* ?)GetWindowLongPtrA(nh.hwndFrom, (i32)GWLP_USERDATA);
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
            UXOutlineView* o = (UXOutlineView* ?)GetWindowLongPtrA(nh.hwndFrom, (i32)GWLP_USERDATA);
            if (o != (UXOutlineView*)0)
                {
                NMTREEVIEW* nt = (NMTREEVIEW*)lp;
                o.nativeDidExpand(nt.nLParam, nt.action == (u32)TVACT_EXPAND ? (i32)1 : (i32)0);
                }
            return (pointer)0;
            }
        if (nh.code == (u32)TVN_SELCHANGEDA)
            {
            UXOutlineView* o = (UXOutlineView* ?)GetWindowLongPtrA(nh.hwndFrom, (i32)GWLP_USERDATA);
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
        UXStepper* stp = (UXStepper* ?)GetWindowLongPtrA(lp, (i32)GWLP_USERDATA);
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
        UXView* sh = (UXView* ?)GetWindowLongPtrA(hwnd, (i32)GWLP_USERDATA);
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
    void windowSetTitle(i32 handle, u8* s)
        {
        u16 wbuf[256]; // UTF-8 -> UTF-16 so a non-ASCII title isn't mangled
        i32 wch = MultiByteToWideChar((u32)CP_UTF8, (u32)0, (pointer)s, (i32)-1, (pointer)&wbuf[0], (i32)256);
        if (wch > (i32)0)
            {
            SetWindowTextW(gW32Hwnds[handle], (pointer)&wbuf[0]);
            }
        // fallback
        else
            {
            SetWindowTextA(gW32Hwnds[handle], (pointer)s);
            }
        }
    void windowSetSubtitle(i32 handle, u8* s)
        {
        }
    void windowSetInfo(i32 handle, u8* s)
        {
        }
    void windowSetIcon(i32 handle, u8* slice)
        {
        }
    void windowSetModified(i32 handle, bool m)
        {
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
    // Wine's comdlg32 file dialog hangs on macOS (it engages but never shows), so use the toolkit panel
    // there — it draws through GDI and works everywhere.  fileOpen (the native GetOpenFileName) is kept
    // below for real Windows; flip this to `true` to prefer it.
    bool hasNativeFileOpen(void)
        {
        return false;
        }
    // toolkit wheel/sliders (native ChooseColor hangs under Wine, like the file dialog)
    bool hasNativeColorPicker(void)
        {
        return false;
        }
    i32 pickColor(i32 r, i32 g, i32 b, i32* outR, i32* outG, i32* outB)
        {
        return (i32)0;
        }
    // toolkit chooser (native ChooseFont hangs under Wine, like ChooseColor)
    bool hasNativeFontPicker(void)
        {
        return false;
        }
    i32 pickFont(u8* inF, i32 inS, i32 inB, i32 inI, u8* outF, i32 cap, i32* outS, i32* outB, i32* outI)
        {
        return (i32)0;
        }
    // Measure in a DC of our own, not gW32CurHdc: line breaking happens during layout, outside any
    // WM_PAINT, when that handle is stale.  One screen-compatible DC, made on first use and kept.
    i32 nowMs(void)
        {
        return (i32)GetTickCount();
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
        pointer fnt = CreateFontA(h, (i32)0, (i32)0, (i32)0, bold ? (i32)700 : (i32)400,
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
        out[0] = (u8)0;
        ofn.lStructSize = (u32)152;
        ofn.hwndOwner = gW32Hwnds[(i32)1];
        ofn.lpstrFilter = (u8*)&filt[0];
        ofn.lpstrFile = out;
        ofn.nMaxFile = (u32)outCap;
        ofn.lpstrInitialDir = startDir;
        ofn.lpstrTitle = prompt;
        ofn.Flags = (u32)OFN_FILEMUSTEXIST | (u32)OFN_PATHMUSTEXIST | (u32)OFN_HIDEREADONLY;
        OleInitialize((pointer)0);
        i32 ok = GetOpenFileNameA((pointer)&ofn);
        OleUninitialize();
        return ok != (i32)0 ? (i32)1 : (i32)0;
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
        x[0] = p.x;
        y[0] = p.y;
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
        UXControl* c = (UXControl* ?)peer;
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

    void realizeTree(i32 handle, pointer tree)
        {
        W32Tree* t = (W32Tree*)tree;
        pointer parent = gW32Hwnds[handle];
        for (i32 i = (i32)0; i < t.count; i = i + (i32)1)
            {
            i32 k = t.nodes[i].kind;
            i32 ax = (i32)0;
            i32 ay = (i32)0;
            i32 w = (i32)0;
            i32 hh = (i32)0;
            self.structAbsFrame(tree, i, &ax, &ay, &w, &hh);
            if (k == (i32)UXKindShield)
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
                    }
                i32 on = self.toggleState(t.nodes[i].peer, k);
                SendMessageA(t.nodes[i].ctrl, (u32)BM_SETCHECK, (pointer)on, (pointer)0); // model -> visual
                }
            else if (k == (i32)UXKindSlider)
                {
                UXSlider* sv = (UXSlider* ?)t.nodes[i].peer;
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
                UXPopUpButton* pv = (UXPopUpButton* ?)t.nodes[i].peer;
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
                UXStepper* sv = (UXStepper* ?)t.nodes[i].peer;
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
                UXProgressBar* pgv = (UXProgressBar* ?)t.nodes[i].peer;
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
                UXSegmentedControl* sg = (UXSegmentedControl* ?)t.nodes[i].peer;
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
                UXToolbar* tbw = (UXToolbar* ?)t.nodes[i].peer;
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
                UXTableView* tv = (UXTableView* ?)t.nodes[i].peer;
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
                UXScrollView* sv = (UXScrollView* ?)t.nodes[i].peer;
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
            UXCheckbox* cb = (UXCheckbox* ?)peer;
            if (cb != (UXCheckbox*)0 && cb.isChecked())
                {
                return (i32)1;
                }
            }
        else
            {
            UXRadioButton* rb = (UXRadioButton* ?)peer;
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
        if ((k == (i32)UXKindSlider || k == (i32)UXKindPopup || k == (i32)UXKindStepper || k == (i32)UXKindProgress || k == (i32)UXKindSegmented || k == (i32)UXKindToolbar) && t.nodes[i].ctrl != (pointer)0)
            {
            return;
            }
        // A SHIELD is app-drawn too: it intercepts input, it is not invisible.
        if ((k == (i32)UXKindView || k == (i32)UXKindShield) && gW32UserFn != (pointer)0)
            {
            UXUserDrawFn* f = (UXUserDrawFn*)gW32UserFn;
            f((pointer)t.nodes, i, gW32UserUd);
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
                    AppendMenuA(sub, flags, (pointer)self.menuId(t, j), (pointer)text);
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
        if (GetMessageA((pointer)&msg, (pointer)0, (u32)0, (u32)0) <= (i32)0)
            {
            ev.kind = (u8)UXEventClose;
            return; // WM_QUIT -> stop the loop
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
        if (msg.message == (u32)WM_CHAR && onWindow != (i32)0)
            {
            ev.kind = (u8)UXEventKeyDown;
            ev.key = (u16)((u32)msg.wParam & (u32)$FF); // ASCII byte
            return;
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
    i32 formFactorClass(void)
        {
        return (i32)UX_FORM_DESKTOP;
        }
    bool driverOwnsRunLoop(void)
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
