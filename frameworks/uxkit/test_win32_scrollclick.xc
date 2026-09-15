// test_win32_scrollclick.xc — a click inside a native scroll container must reach the view it lands on.
//
// On Win32 an UXScrollView is realized as a real WS_VSCROLL child window (class UXScroll32) that paints
// the document subtree itself.  A click therefore lands on THAT child, not on the window's canvas, so
// nextEvent — which only decodes clicks on a top-level UXKit window — never saw it, and a self-drawn view
// inside a scroll view (the font chooser's family list) could not be selected.  The child proc now undoes
// its own paint transform (child client -> parent client, plus the bar position) and posts the click to
// the parent, where the ordinary hit test finds the view.
//
// The marker sits at document y=60, so it is at absolute y=80 under a scroll view at y=20.  Unscrolled it
// is at child-client y=60; after scrolling 40px it is at child-client y=20 — and a click at each of those
// must land on it.  That second case is what proves the bar position is folded in.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"

class MarkView : UXView
    {
    i32 hits;
    i32 lastY;
    void init(void)
        {
        super.init();
        hits = (i32)0;
        lastY = (i32)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        }
    void mouseDown(UXEvent* e)
        {
        hits = hits + (i32)1;
        lastY = (i32)e.y;
        }
    }

    // Pump the queue until the posted click comes back out as a neutral mouse-down (or we run dry).
    i32 pumpClick(UXWindow* win)
    {
    UXEvent* ev = new UXEvent();
    for (i32 i = (i32)0; i < (i32)16; i = i + (i32)1)
        {
        gDriver.nextEvent((i32)0, ev);
        if (ev.kind == (u8)UXEventMouseDown)
            {
            win.dispatchMouse(ev);
            return (i32)1;
            }
        // WM_QUIT — nothing more is coming
        if (ev.kind == (u8)UXEventClose)
            {
            return (i32)0;
            }
        }
    return (i32)0;
    }

void main(void)
    {
    UXWin32Driver* drv = new UXWin32Driver();
    gDriver = drv;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);

    UXWindow* win = new UXWindow();
    UXView* content = new UXView();
    win.open((u8*)"ScrollClick", UXGeom.make((i16)60, (i16)60, (i16)300, (i16)240), content);
    UXScrollView* sv = new UXScrollView();
    content.addSubview(sv, UXGeom.make((i16)20, (i16)20, (i16)200, (i16)120));
    sv.setLineHeight((i16)20);
    MarkView* mark = new MarkView();
    sv.document().addSubview(mark, UXGeom.make((i16)0, (i16)60, (i16)180, (i16)20));
    sv.setDocumentHeight((i32)400);
    win.tree.finalise();
    win.displayAll(); // realizeTree creates the native UXScroll32 child

    // The container's HWND: realizeTree gives every native child the control id W32_CTRL_ID_BASE + node.
    pointer child = GetDlgItem(drv.windowNative(win.handle), (i32)W32_CTRL_ID_BASE + (i32)sv.index);
    if (child == (pointer)0)
        {
        Stdio.printf("no scroll child HWND\nFAIL\n");
        return;
        }

    // 1) unscrolled: the marker is at child-client y=60.
    SendMessageA(child, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)(((u32)65 << (u32)16) | (u32)10));
    pumpClick(win);
    i32 hits1 = mark.hits;
    i32 y1 = mark.lastY;

    // 2) scrolled 40px: the same marker is now at child-client y=20.
    SetScrollPos(child, (i32)SB_VERT, (i32)40, (i32)1);
    SendMessageA(child, (u32)WM_LBUTTONDOWN, (pointer)0, (pointer)(((u32)25 << (u32)16) | (u32)10));
    pumpClick(win);
    i32 hits2 = mark.hits;
    i32 y2 = mark.lastY;

    Stdio.printf("unscrolled: hits=%d y=%d ; scrolled40: hits=%d y=%d\n", hits1, y1, hits2, y2);
    // Both clicks must reach the marker (abs y 80..100), the second only if the bar position is folded in.
    i32 ok = (hits1 == (i32)1 && y1 >= (i32)80 && y1 < (i32)100 && hits2 == (i32)2 && y2 >= (i32)80 && y2 < (i32)100) ? (i32)1 : (i32)0;
    Stdio.printf("scrollClickRouted=%d\n", ok);
    Stdio.printf("done\n");
    }
