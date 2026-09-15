// test_springs.xc — the neutral springs & struts solver (UXView.resizeSubviews), headless.
//
// The SAME mask that drives AppKit's native NSView autoresizing drives the neutral layout the other
// backends use.  This builds children with assorted masks in a 200x100 parent, grows it to 300x150
// (dw=+100, dh=+50), and checks each child's new frame.  Backend-neutral math; run on any driver.
//
//   Build+run:  cc -fobjc-arc -c libUXAppKit.m -o /tmp/l.o &&
//               xtc -A arm64 -I . test_springs.xc -Xlinker /tmp/l.o -framework Cocoa -o /tmp/t && /tmp/t
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXViewDriver.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

i32 gFails;
void chk(u8* what, i32 got, i32 want)
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
void expect(u8* name, UXView* v, i32 x, i32 y, i32 w, i32 h)
    {
    UXRect f = v.frame();
    if ((i32)f.x == x && (i32)f.y == y && (i32)f.w == w && (i32)f.h == h)
        {
        Stdio.printf("  ok   %s = %d,%d,%d,%d\n", name, (i16)f.x, (i16)f.y, (i16)f.w, (i16)f.h);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d,%d,%d,%d (want %d,%d,%d,%d)\n", name,
                     (i16)f.x, (i16)f.y, (i16)f.w, (i16)f.h, (i16)x, (i16)y, (i16)w, (i16)h);
        gFails = gFails + (i32)1;
        }
    }
UXView* child(UXView* parent, i32 x, i32 y, i32 w, i32 h, i32 mask)
    {
    UXView* v = new UXView();
    parent.addSubview(v, UXGeom.make((i16)x, (i16)y, (i16)w, (i16)h));
    v.setAutoresizeMask(mask);
    return v;
    }

class Del : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        gFails = (i32)0;
        UXWindow* win = new UXWindow();
        UXView* c = new UXView();
        win.open((u8*)"S", UXGeom.make((i16)0, (i16)0, (i16)200, (i16)100), c);
        app.addWindow(win);

        UXView* pinTL = child(c, (i32)10, (i32)10, (i32)50, (i32)20, (i32)0);
        UXView* pinR = child(c, (i32)140, (i32)10, (i32)50, (i32)20, (i32)UX_ANCHOR_RIGHT);
        UXView* flexW = child(c, (i32)10, (i32)40, (i32)180, (i32)20, (i32)UX_FLEX_WIDTH);
        UXView* pinBR = child(c, (i32)140, (i32)70, (i32)50, (i32)20, (i32)UX_ANCHOR_RIGHT | (i32)UX_ANCHOR_BOTTOM);
        UXView* flexB = child(c, (i32)10, (i32)10, (i32)100, (i32)50, (i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        UXView* stretchW = child(c, (i32)10, (i32)10, (i32)180, (i32)20, (i32)UX_ANCHOR_LEFT | (i32)UX_ANCHOR_RIGHT);
        UXView* prop = child(c, (i32)100, (i32)10, (i32)50, (i32)20, (i32)UX_ANCHOR_RIGHT | (i32)UX_FLEX_WIDTH);

        c.resizeSubviews((i32)200, (i32)100, (i32)300, (i32)150); // dw=+100, dh=+50

        expect((u8*)"pin top-left  (mask 0)     stays", pinTL, (i32)10, (i32)10, (i32)50, (i32)20);
        expect((u8*)"anchor right  moves +100 x", pinR, (i32)240, (i32)10, (i32)50, (i32)20);
        expect((u8*)"flex width    grows +100 w", flexW, (i32)10, (i32)40, (i32)280, (i32)20);
        expect((u8*)"anchor bottom-right   +100/+50", pinBR, (i32)240, (i32)120, (i32)50, (i32)20);
        expect((u8*)"flex both     grows +100/+50", flexB, (i32)10, (i32)10, (i32)200, (i32)100);
        expect((u8*)"left+right    stretches width", stretchW, (i32)10, (i32)10, (i32)280, (i32)20);
        // proportional (both margin AND size flex): left 100 + size 50 share +100 -> +66 / +34
        expect((u8*)"anchor-R + flex-W  proportional", prop, (i32)166, (i32)10, (i32)84, (i32)20);

        ux_ak_post_quit();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    gDriver = new UXAppKitDriver();
    Del* del = new Del();
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    app.run();
    Stdio.printf(gFails == (i32)0
                     ? "PASS: the neutral springs & struts solver lays out every mask correctly\n"
                     : "FAIL: %d spring checks failed\n",
                 (i16)gFails);
    }
