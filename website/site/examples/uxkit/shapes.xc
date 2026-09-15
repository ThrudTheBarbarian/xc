// shapes.xc — UXShapePath: vector paths with curves, flattened on demand.
//
// Pure integer geometry. No driver, no window, no backend — which is why a
// custom-shaped control can hit-test itself in a unit test.
#import <Stdio.xc>
#import "UXShapePath.xc"

void showBounds(u8* label, UXShapePath* p) {
    UXRect b = p.boundingBox();
    Stdio.printf("%s x=%d y=%d w=%d h=%d edges=%d\n",
                 label, b.x, b.y, b.w, b.h, (i32)p.edges().count());
}

void main(void) {
    // ---- straight lines --------------------------------------------------
    UXShapePath* tri = new UXShapePath();
    tri.moveTo((i16)10, (i16)10);
    tri.lineTo((i16)90, (i16)10);
    tri.lineTo((i16)50, (i16)80);
    tri.close();

    showBounds((u8*)"triangle: ", tri);
    Stdio.printf("has curves: %d\n", tri.hasCurves() ? 1 : 0);

    // Containment is even-odd ray casting over the edges.
    Stdio.printf("inside (50,30)=%d  outside (5,5)=%d  outside (50,90)=%d\n",
                 tri.containsPoint((i16)50, (i16)30) ? 1 : 0,
                 tri.containsPoint((i16)5,  (i16)5)  ? 1 : 0,
                 tri.containsPoint((i16)50, (i16)90) ? 1 : 0);

    // A subpath is closed IMPLICITLY for containment, so the edge count is the
    // same whether or not close() was called.
    UXShapePath* open = new UXShapePath();
    open.moveTo((i16)10, (i16)10);
    open.lineTo((i16)90, (i16)10);
    open.lineTo((i16)50, (i16)80);
    showBounds((u8*)"unclosed: ", open);
    Stdio.printf("still contains (50,30): %d\n",
                 open.containsPoint((i16)50, (i16)30) ? 1 : 0);

    // ---- curves are STORED, not flattened on the way in -------------------
    UXShapePath* blob = new UXShapePath();
    blob.moveTo((i16)20, (i16)50);
    blob.curveTo((i16)20, (i16)10, (i16)80, (i16)10, (i16)80, (i16)50);
    blob.curveTo((i16)80, (i16)90, (i16)20, (i16)90, (i16)20, (i16)50);

    Stdio.printf("blob has curves: %d\n", blob.hasCurves() ? 1 : 0);
    showBounds((u8*)"blob:     ", blob);

    // flattened() produces the polyline on demand; the original keeps its
    // curves, so it can be asked again at a different resolution.
    UXShapePath* flat = blob.flattened();
    Stdio.printf("flattened has curves: %d  edges=%d\n",
                 flat.hasCurves() ? 1 : 0, (i32)flat.edges().count());
    Stdio.printf("original still curved: %d\n", blob.hasCurves() ? 1 : 0);

    // Containment on a curved path routes through the flattening, so a curve
    // behaves like the polyline that approximates it.
    Stdio.printf("blob contains (50,50)=%d  (50,5)=%d\n",
                 blob.containsPoint((i16)50, (i16)50) ? 1 : 0,
                 blob.containsPoint((i16)50, (i16)5)  ? 1 : 0);

    // A quadratic is elevated to a cubic on the way in — one curve type to
    // flatten, rather than two.
    UXShapePath* q = new UXShapePath();
    q.moveTo((i16)0, (i16)0);
    q.quadTo((i16)50, (i16)100, (i16)100, (i16)0);
    Stdio.printf("quad became a curve: %d\n", q.hasCurves() ? 1 : 0);
    showBounds((u8*)"quad:     ", q);

    // ---- multiple subpaths ------------------------------------------------
    // Even-odd fill: a hole inside a shape is a second subpath, and points in
    // the hole are OUTSIDE.
    UXShapePath* ring = new UXShapePath();
    ring.moveTo((i16)0,   (i16)0);
    ring.lineTo((i16)100, (i16)0);
    ring.lineTo((i16)100, (i16)100);
    ring.lineTo((i16)0,   (i16)100);
    ring.close();
    ring.moveTo((i16)40, (i16)40);
    ring.lineTo((i16)60, (i16)40);
    ring.lineTo((i16)60, (i16)60);
    ring.lineTo((i16)40, (i16)60);
    ring.close();

    showBounds((u8*)"ring:     ", ring);
    Stdio.printf("in the wall (10,50)=%d   in the hole (50,50)=%d\n",
                 ring.containsPoint((i16)10, (i16)50) ? 1 : 0,
                 ring.containsPoint((i16)50, (i16)50) ? 1 : 0);

    // ---- the rect shortcut ------------------------------------------------
    UXShapePath* r = UXShapePath.rect((i16)5, (i16)5, (i16)20, (i16)10);
    showBounds((u8*)"rect:     ", r);

    // ---- caps are a property of the SHAPE ---------------------------------
    UXShapePath* arrow = new UXShapePath();
    arrow.moveTo((i16)0, (i16)0);
    arrow.lineTo((i16)100, (i16)0);
    arrow.setEndCap((i32)UXCAP_ARROW);
    arrow.setCapWidth((i16)6);
    UXShapePath* head = arrow.capOutline(false, (i16)6);
    Stdio.printf("arrowhead outline edges: %d\n",
                 head == (UXShapePath*)0 ? (i32)0 : (i32)head.edges().count());

    // An empty path answers rather than trapping.
    UXShapePath* nothing = new UXShapePath();
    showBounds((u8*)"empty:    ", nothing);
    Stdio.printf("empty contains (0,0): %d\n",
                 nothing.containsPoint((i16)0, (i16)0) ? 1 : 0);
}
