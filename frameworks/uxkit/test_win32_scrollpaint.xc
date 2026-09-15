// test_win32_scrollpaint.xc — a programmatic repaint must reach inside a native scroll container.
//
// An UXScrollView is a separate HWND on Win32 (class UXScroll32) that paints its own slice of the
// tree.  InvalidateRect on the window's client area does NOT touch a child window, so a change made
// from code — a row appended, a selection set without a click — used to sit unpainted until
// something else happened to expose the container.  windowInvalidate/windowInvalidateRect now walk
// the driver's table of live containers as well.
//
// Each marker counts its own drawRect calls.  Two of them, and the DEEP one is what matters:
//
//   near  — document y=40, so absolute y=60: inside the container's frame (20..140).  Its damage
//           rect overlaps the container, and since the parent lacks WS_CLIPCHILDREN the parent's
//           erase drags the child into the repaint anyway.  A sanity check, not the guard.
//   far   — document y=300, so absolute y=320: BELOW the container's frame entirely.  Scroll the
//           bar down and it is on screen, but the damage rect the toolkit reports (unscrolled
//           absolute space) names a region the container does not cover, so nothing about the
//           parent's repaint reaches it.  Only invalidating the container itself paints it.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"

class CountView : UXView
    {
    i32 paints;
    void init(void)
        {
        super.init();
        paints = (i32)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        paints = paints + (i32)1;
        }
    }

    void
    main(void)
    {
    UXWin32Driver* drv = new UXWin32Driver();
    gDriver = drv;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);

    UXWindow* win = new UXWindow();
    UXView* content = new UXView();
    win.open((u8*)"ScrollPaint", UXGeom.make((i16)60, (i16)60, (i16)300, (i16)240), content);
    UXScrollView* sv = new UXScrollView();
    content.addSubview(sv, UXGeom.make((i16)20, (i16)20, (i16)200, (i16)120));
    CountView* near = new CountView();
    sv.document().addSubview(near, UXGeom.make((i16)0, (i16)40, (i16)180, (i16)20));
    CountView* far = new CountView();
    sv.document().addSubview(far, UXGeom.make((i16)0, (i16)300, (i16)180, (i16)20));
    sv.setDocumentHeight((i32)400);
    win.tree.finalise();
    win.displayAll(); // realizes the container and paints it once
    pointer child = GetDlgItem(drv.windowNative(win.handle), (i32)W32_CTRL_ID_BASE + (i32)sv.index);
    if (child == (pointer)0)
        {
        Stdio.printf("no scroll child HWND\nFAIL\n");
        return;
        }
    UpdateWindow(child);
    i32 first = near.paints;

    // 1) in view, damage rect over the container: dirty it from code (no click) and display.
    near.setNeedsDisplay();
    win.display();
    UpdateWindow(child);
    i32 afterNear = near.paints;

    // 2) the deep one, scrolled into view: its damage rect lies below the container entirely.
    SetScrollPos(child, (i32)SB_VERT, (i32)240, (i32)1);
    InvalidateRect(child, (pointer)0, (i32)0);
    UpdateWindow(child); // settle the scrolled state
    i32 base = far.paints;
    far.setNeedsDisplay();
    win.display();
    UpdateWindow(child);
    i32 afterFar = far.paints;

    Stdio.printf("near: first=%d after=%d ; far: base=%d after=%d\n", first, afterNear, base, afterFar);
    i32 ok = (first > (i32)0 && afterNear > first && afterFar > base) ? (i32)1 : (i32)0;
    Stdio.printf("scrollRepaintReaches=%d\n", ok);
    Stdio.printf("done\n");
    }
