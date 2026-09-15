// test_viewport.xc — UXViewport pan/zoom coordinate mapping + zoom-about-a-point.
#import <Stdio.xc>
#import "UXViewport.xc"
#import "UXGeometry.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    UXViewport* vp = new UXViewport();

    // identity
    check("1:1 doc->screen x", vp.docToScreenX((i32)50), (i32)50);
    check("1:1 screen->doc x", vp.screenToDocX((i32)50), (i32)50);

    // pan
    vp.panTo((i32)100, (i32)20);
    check("panned doc->screen x", vp.docToScreenX((i32)50), (i32)150); // 50 + 100
    check("panned screen->doc x", vp.screenToDocX((i32)150), (i32)50);
    vp.panBy((i32)-100, (i32)-20); // back to 0,0
    check("pan back", vp.docToScreenX((i32)50), (i32)50);

    // zoom 200%
    vp.setZoom((i32)200);
    check("2x doc->screen", vp.docToScreenX((i32)50), (i32)100); // 50 * 200/100
    check("2x screen->doc", vp.screenToDocX((i32)100), (i32)50);
    check("2x doc->screen y", vp.docToScreenY((i32)30), (i32)60);

    // zoom 50%
    vp.setZoom((i32)50);
    check("0.5x doc->screen", vp.docToScreenX((i32)80), (i32)40);

    // round trip at an arbitrary zoom
    vp.setZoom((i32)150);
    vp.panTo((i32)10, (i32)5);
    check("round-trip x", vp.screenToDocX(vp.docToScreenX((i32)64)), (i32)64);

    // zoom about a point: the doc point under screen (200,100) stays put
    UXViewport* z = new UXViewport();
    z.setZoom((i32)100);
    z.panTo((i32)0, (i32)0);
    i32 docXbefore = z.screenToDocX((i32)200);
    z.zoomAtPoint((i32)300, (i32)200, (i32)100);
    check("zoom changed to 300", z.zoom, (i32)300);
    // the same doc point must still map to screen x=200
    check("anchor point x stays fixed", z.docToScreenX(docXbefore), (i32)200);
    check("anchor point y stays fixed", z.docToScreenY(z.screenToDocY((i32)100)), (i32)100);

    // visible doc rect at 200% in a 400x300 screen viewport (pan 0): doc rect is 200x150
    UXViewport* v2 = new UXViewport();
    v2.setZoom((i32)200);
    UXRect r = v2.visibleDocRect((i32)400, (i32)300);
    check("visible doc width halved", (i32)r.w, (i32)200);
    check("visible doc height halved", (i32)r.h, (i32)150);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXViewport — pan, zoom, round-trip, zoom-about-point, visible rect.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
