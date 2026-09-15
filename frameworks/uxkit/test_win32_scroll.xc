// test_win32_scroll.xc — scrolling on the Win32 backend (both axes).
//
// The neutral toolkit's whole share of "scrolling" is layoutFor subtracting the driver's scroll
// offset: the root moves, every child is parent-relative, so the tree scrolls — and the shadow-
// tree hit test walks the SAME moved tree, so hit-testing scrolls for free (§11).  The Win32
// driver supplies the offset from native WS_VSCROLL / WS_HSCROLL bars (WM_VSCROLL / WM_HSCROLL).
// A marker at (300,300) in a 200x200 window is off-screen until we scroll (200,200), which brings
// it to absolute (100,100) — where a click now lands on it.
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"

void main(void)
    {
    gDriver = new UXWin32Driver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);

    UXWindow* win = new UXWindow();
    UXView* content = new UXView();
    UXView* marker = new UXView();
    win.open((u8*)"Scroll", UXGeom.make((i16)80, (i16)80, (i16)200, (i16)200), content);
    content.addSubview(marker, UXGeom.make((i16)300, (i16)300, (i16)100, (i16)20));
    win.setContentSize((i16)400, (i16)400); // content bigger than the window, both ways
    win.displayAll();

    UXRect b = marker.absoluteFrame();
    i32 hitBefore = win.tree.hitTest((i16)110, (i16)110);
    win.scrollTo((i16)200, (i16)200); // scroll right 200, down 200
    UXRect a = marker.absoluteFrame();
    i32 hitAfter = win.tree.hitTest((i16)110, (i16)110);
    i32 mi = (i32)marker.index;

    Stdio.printf("before=%d,%d after=%d,%d scroll=%d,%d\n",
                 (i32)b.x, (i32)b.y, (i32)a.x, (i32)a.y, (i32)win.scrollX(), (i32)win.scrollY());
    Stdio.printf("hitTest(110,110): before=%d after=%d marker=%d\n", hitBefore, hitAfter, mi);
    if ((i32)b.x == (i32)300 && (i32)b.y == (i32)300 && (i32)a.x == (i32)100 && (i32)a.y == (i32)100 && (i32)win.scrollX() == (i32)200 && (i32)win.scrollY() == (i32)200 && hitAfter == mi && hitBefore != mi)
        {
        Stdio.printf("PASS: the tree and hit-testing scroll on both axes\n");
        }
    else
        {
        Stdio.printf("FAIL\n");
        }
    }
