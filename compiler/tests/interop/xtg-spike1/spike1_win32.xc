#import "Stdio.xc"

// ── Win32 bindings ──────────────────────────────────────────────────────────
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
    }

    pointer
    GetModuleHandleA(pointer name);
u16 RegisterClassA(pointer wc);
pointer CreateWindowExA(u32 ex, pointer cls, pointer name, u32 style,
                        i32 x, i32 y, i32 w, i32 h, pointer par, pointer menu, pointer inst, pointer p);
pointer DefWindowProcA(pointer hwnd, u32 msg, pointer wp, pointer lp);
i32 ShowWindow(pointer hwnd, i32 cmd);
i32 PostMessageA(pointer hwnd, u32 msg, pointer wp, pointer lp);
i32 DestroyWindow(pointer hwnd);
void PostQuitMessage(i32 code);
i32 GetMessageA(pointer msg, pointer hwnd, u32 mn, u32 mx);
i32 TranslateMessage(pointer msg);
pointer DispatchMessageA(pointer msg);
pointer SetWindowLongPtrA(pointer hwnd, i32 idx, pointer v);
pointer GetWindowLongPtrA(pointer hwnd, i32 idx);
i32 InvalidateRect(pointer hwnd, pointer r, i32 erase);
i32 UpdateWindow(pointer hwnd);
pointer BeginPaint(pointer hwnd, pointer ps);
i32 EndPaint(pointer hwnd, pointer ps);
i32 FillRect(pointer hdc, pointer r, pointer br);
pointer CreateSolidBrush(u32 color);
i32 DeleteObject(pointer o);

// ── Neutral Xtg layer (would live in generic/lib) ───────────────────────────
// the portable drawing primitive over a native DC
class XGContext
    {
    pointer hdc;
    void fillRect(i32 x, i32 y, i32 w, i32 h, u32 color)
        {
        RECT r;
        r.left = x;
        r.top = y;
        r.right = x + w;
        r.bottom = y + h;
        pointer br = CreateSolidBrush(color);
        FillRect(self.hdc, &r, br);
        DeleteObject(br);
        Stdio.printf("fill=%d,%d,%d,%d\n", x, y, w, h);
        }
    // the responder; a subclass overrides these
    } class XGView
    {
    pointer handle;
    void drawRect(XGContext* g)
        {
        }
    void mouseDown(u16 x, u16 y)
        {
        }
    }

    // ── The Win32 driver: one shared WndProc + the reverse map ──────────────────
    pointer WndProc(pointer hwnd, u32 msg, pointer wp, pointer lp)
    {
    XGView* v = (XGView*)GetWindowLongPtrA(hwnd, (i32)-21); // GWLP_USERDATA reverse map
    // WM_PAINT
    if (msg == (u32)$000F)
        {
        PAINTSTRUCT ps;
        pointer hdc = BeginPaint(hwnd, &ps);
        if (v != (XGView*)0)
            {
            XGContext* g = new XGContext();
            g.hdc = hdc;
            v.drawRect(g);
            }
        EndPaint(hwnd, &ps);
        return (pointer)0;
        }
    // WM_LBUTTONDOWN
    if (msg == (u32)$0201)
        {
        u32 lpw = (u32)lp;
        if (v != (XGView*)0)
            {
            v.mouseDown((u16)lpw, (u16)(lpw >> (u32)16));
            }
        DestroyWindow(hwnd);
        return (pointer)0;
        }
    // WM_DESTROY
    if (msg == (u32)$0002)
        {
        PostQuitMessage(0);
        return (pointer)0;
        }
    return DefWindowProcA(hwnd, msg, wp, lp);
    }

// ── App code (would be the portable source) ─────────────────────────────────
class MyView : XGView
    {
    void drawRect(XGContext* g)
        {
        g.fillRect((i32)10, (i32)10, (i32)50, (i32)30, (u32)$0000FF00);
        }
    void mouseDown(u16 x, u16 y)
        {
        Stdio.printf("mouseDown=%d,%d\n", x, y);
        }
    }

    pointer gClassName;
void main(void)
    {
    pointer inst = GetModuleHandleA((pointer)0);
    WNDCLASSA wc;
    wc.style = (u32)0;
    wc._p0 = (u32)0;
    wc.lpfnWndProc = &WndProc;
    wc.cbClsExtra = (i32)0;
    wc.cbWndExtra = (i32)0;
    wc.hInstance = inst;
    wc.hIcon = (pointer)0;
    wc.hCursor = (pointer)0;
    wc.hbrBackground = (pointer)0;
    wc.lpszMenuName = (pointer)0;
    wc.lpszClassName = (pointer) "XtgS1";
    Stdio.printf("register=%d\n", (i32)(RegisterClassA(&wc) != (u16)0));

    pointer hwnd = CreateWindowExA((u32)0, (pointer) "XtgS1", (pointer) "s1",
                                   (u32)$00CF0000, (i32)100, (i32)100, (i32)320, (i32)240,
                                   (pointer)0, (pointer)0, inst, (pointer)0);
    Stdio.printf("window=%d\n", (i32)(hwnd != (pointer)0));

    MyView* view = new MyView();
    view.handle = hwnd;
    SetWindowLongPtrA(hwnd, (i32)-21, (pointer)view); // install reverse map
    ShowWindow(hwnd, (i32)5);
    InvalidateRect(hwnd, (pointer)0, (i32)1);
    UpdateWindow(hwnd); // force a paint

    pointer clk = (pointer)((u32)30 | ((u32)40 << (u32)16));
    PostMessageA(hwnd, (u32)$0201, (pointer)0, clk); // inject a click

    MSG msg;
    while (GetMessageA(&msg, (pointer)0, (u32)0, (u32)0) > (i32)0)
        {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
        }
    Stdio.printf("done\n");
    }
