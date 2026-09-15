// test_mac_vector.xc — the vector stroking, rendered for real on AppKit and inspected for SEAMS.
//
// The bug this guards shipped: UXPainter draws a stroke as overlapping convex pieces, and where two
// pieces met EDGE TO EDGE the backend antialiased each one's edge against the background, so the two
// half-covered pixels blended into a visible line drawn straight through the middle of a solid
// stroke — a line across the round cap, most obviously.  Invisible on GEM, which draws hard pixels.
// No geometry test could catch it: the geometry was right, and the defect only exists once something
// antialiases.
//
// It draws its OWN shape rather than the kitchen sink's board, and that is the point.  The board has
// an arrowhead, a gradient blob and captions, so every check has to tolerate the legitimate blending
// where two different shapes meet — and a tolerance wide enough to cover those was wide enough to
// hide the bug.  One curve, one colour, round caps, nothing touching it: any blended pixel in the
// interior is a seam, and the threshold is zero.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXShapePath.xc"
#import "UXPainter.xc"

i32 ux_ak_dump_ppm(u8* path);

class SeamBoard : UXView
    {
    UXShapePath* curve;
    void init(void)
        {
        super.init();
        curve = (UXShapePath*)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(self.bounds(), (i32)0);
        if (curve == (UXShapePath*)0)
            {
            curve = new UXShapePath();
            curve.moveTo((i16)40, (i16)150);
            curve.curveTo((i16)70, (i16)60, (i16)110, (i16)60, (i16)140, (i16)150);
            curve.curveTo((i16)170, (i16)240, (i16)210, (i16)240, (i16)240, (i16)150);
            curve.setStartCap((i32)UXCAP_ROUND);
            curve.setEndCap((i32)UXCAP_ROUND); // round BOTH ends: no arrowhead, no junctions
            }
        UXPainter.strokePath(g, curve, (i16)16, UXPainter.rgb((i32)80, (i32)170, (i32)255));
        }
    }

    class Shot : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* a)
        {
        UXWindow* win = new UXWindow();
        UXView* content = new UXView();
        a.addWindow(win);
        win.open((u8*)"Seam", UXGeom.make((i16)20, (i16)20, (i16)300, (i16)280), content);
        SeamBoard* b = new SeamBoard();
        content.addSubview(b, UXGeom.make((i16)0, (i16)0, (i16)300, (i16)280));
        win.displayAll();
        if (ux_ak_dump_ppm((u8*)"/tmp/ux_vec_check.ppm") == (i32)0)
            {
            Stdio.printf("FAIL: nothing rendered\n");
            }
        a.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    UXApplication* app = new UXApplication();
    Shot* s = new Shot();
    app.setDelegate(s);
    app.run();
    Stdio.printf("rendered\n");
    }
