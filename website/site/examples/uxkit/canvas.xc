// canvas.xc — UXGradient and UXViewport: the two integer mappers behind a
// scrollable, zoomable, themed canvas.
//
// Both are pure arithmetic with no driver and no window, which is what makes a
// zoom-toward-the-cursor gesture testable without a mouse.
#import <Stdio.xc>
#import "UXGradient.xc"
#import "UXViewport.xc"

void sample(u8* label, UXGradient* g) {
    Stdio.printf("%s", label);
    i32 ts[5]; ts[0]=(i32)0; ts[1]=(i32)64; ts[2]=(i32)128; ts[3]=(i32)192; ts[4]=(i32)255;
    for (i32 i = (i32)0; i < (i32)5; i = i + (i32)1) {
        UXColor* c = g.colorAt(ts[i]);
        Stdio.printf(" %d:(%d,%d,%d)", ts[i], c.r, c.g, c.b);
    }
    Stdio.printf("\n");
}

void main(void) {
    // ---- gradients --------------------------------------------------------
    UXGradient* g = UXGradient.twoColor(UXColor.black(), UXColor.white());
    Stdio.printf("two-colour stops=%d\n", g.stopCount());
    sample((u8*)"black->white:", g);

    // A third stop in the middle bends the ramp. Stops stay sorted by position
    // however they are added.
    UXGradient* sunset = new UXGradient();
    sunset.addStop((i32)255, UXColor.rgb((i32)0,   (i32)0,   (i32)80));
    sunset.addStop((i32)0,   UXColor.rgb((i32)255, (i32)200, (i32)0));
    sunset.addStop((i32)128, UXColor.rgb((i32)220, (i32)60,  (i32)40));
    Stdio.printf("sunset stops in order:");
    for (i32 i = (i32)0; i < sunset.stopCount(); i = i + (i32)1) {
        Stdio.printf(" %d", sunset.stopAt(i).pos);
    }
    Stdio.printf("\n");
    sample((u8*)"sunset:      ", sunset);

    // Outside the stop range the end colours are CLAMPED, not extrapolated.
    UXGradient* narrow = new UXGradient();
    narrow.addStop((i32)100, UXColor.rgb((i32)255, (i32)0, (i32)0));
    narrow.addStop((i32)150, UXColor.rgb((i32)0, (i32)0, (i32)255));
    sample((u8*)"narrow band: ", narrow);

    // Positions are clamped to 0..255 on the way in.
    UXGradient* clamped = new UXGradient();
    clamped.addStop(-(i32)50, UXColor.red());
    clamped.addStop((i32)999, UXColor.blue());
    Stdio.printf("clamped stop positions: %d %d\n",
                 clamped.stopAt((i32)0).pos, clamped.stopAt((i32)1).pos);

    // An empty gradient answers black rather than trapping.
    UXGradient* empty = new UXGradient();
    UXColor* e = empty.colorAt((i32)128);
    Stdio.printf("empty gradient: (%d,%d,%d) stops=%d\n",
                 e.r, e.g, e.b, empty.stopCount());

    // ---- viewport ---------------------------------------------------------
    UXViewport* vp = new UXViewport();
    Stdio.printf("\ndefault: zoom=%d pan=%d,%d\n", vp.zoom, vp.panX, vp.panY);
    Stdio.printf("1:1 doc(100,50) -> screen(%d,%d)\n",
                 vp.docToScreenX((i32)100), vp.docToScreenY((i32)50));

    vp.setZoom((i32)200);
    vp.panTo((i32)10, (i32)20);
    Stdio.printf("200%% pan(10,20): doc(100,50) -> screen(%d,%d)\n",
                 vp.docToScreenX((i32)100), vp.docToScreenY((i32)50));
    Stdio.printf("  and back: screen(%d,%d) -> doc(%d,%d)\n",
                 vp.docToScreenX((i32)100), vp.docToScreenY((i32)50),
                 vp.screenToDocX(vp.docToScreenX((i32)100)),
                 vp.screenToDocY(vp.docToScreenY((i32)50)));

    // zoomAtPoint keeps the document point under the cursor FIXED, which is
    // what "zoom toward the pointer" means.
    UXViewport* z = new UXViewport();
    i32 cursorX = (i32)320; i32 cursorY = (i32)240;
    i32 underBefore = z.screenToDocX(cursorX);
    z.zoomAtPoint((i32)400, cursorX, cursorY);
    Stdio.printf("zoomAtPoint 100%%->400%% at (320,240):\n");
    Stdio.printf("  doc under cursor before=%d after=%d  pan now %d,%d\n",
                 underBefore, z.screenToDocX(cursorX), z.panX, z.panY);
    z.zoomAtPoint((i32)50, cursorX, cursorY);
    Stdio.printf("  then 400%%->50%%: doc under cursor=%d zoom=%d\n",
                 z.screenToDocX(cursorX), z.zoom);

    // Zoom is clamped to at least 1%, so the inverse mapping never divides by
    // zero.
    UXViewport* tiny = new UXViewport();
    tiny.setZoom((i32)0);
    Stdio.printf("setZoom(0) -> %d;  setZoom(-5) -> ", tiny.zoom);
    tiny.setZoom(-(i32)5);
    Stdio.printf("%d\n", tiny.zoom);

    // What is on screen, in document terms — what a redraw culls against.
    UXViewport* v2 = new UXViewport();
    v2.setZoom((i32)200);
    v2.panTo(-(i32)100, -(i32)60);
    UXRect vis = v2.visibleDocRect((i32)640, (i32)480);
    Stdio.printf("visible doc rect at 200%%: x=%d y=%d w=%d h=%d\n",
                 vis.x, vis.y, vis.w, vis.h);

    v2.setZoom((i32)50);
    vis = v2.visibleDocRect((i32)640, (i32)480);
    Stdio.printf("visible doc rect at 50%%:  x=%d y=%d w=%d h=%d\n",
                 vis.x, vis.y, vis.w, vis.h);
}
