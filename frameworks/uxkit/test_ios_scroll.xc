// test_ios_scroll.xc — a scroll view on iOS is a UIScrollView (the ios-scroll gate).
//
// The gtk-scroll scene: a scroll view 150 tall over a 600-tall document, two drawn markers, A near
// the top and B far down, and a native button below B.  Checked: the container is a UIScrollView, it
// owns the offset and the native button has moved into its document; a tap on A, entering at a point
// of the window as it shows (onto the document, where UIKit's touches do), reaches A; scrolling from
// the app moves the container and the toolkit reads the offset back from it; then a tap where B shows
// reaches B, and the picture shows B and the button where the scroll put them.
#import <Stdio.xc>
#import "UXIosDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
extern i32 ux_ios_test_scroll_native(i32 handle, i32 node);
extern i32 ux_ios_test_in_scroll_doc(i32 handle, i32 node, i32 scrollNode);
extern void ux_ios_test_tap_doc(i32 handle, i32 node, i32 x, i32 y);
extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_call_later(pointer fn, i32 ms);

i32 gFails;
void ck(u8* what, bool ok)
    {
    if (ok)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

class Back : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)255, (i32)255, (i32)255);
        }
    }
class Page : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)235, (i32)235, (i32)240);
        }
    }
class Marker : UXView
    {
    i32 r;
    i32 g;
    i32 b;
    i32 clicks;
    i32 hovers;
    i32 localY; // where in the marker the last press landed
    void drawRect(UXGraphics* gr, UXRect dirty)
        {
        gr.fillRectRGB(self.bounds(), r, g, b);
        }
    void mouseDown(UXEvent* e)
        {
        clicks = clicks + (i32)1;
        localY = (i32)e.y - (i32)self.absoluteFrame().y;
        }
    void mouseMoved(UXEvent* e)
        {
        hovers = hovers + (i32)1;
        }
    }
// an event as an app's own code (or a headless gate) hands it to the window: content coordinates
void synth(UXWindow* w, i32 kind, i32 x, i32 y)
    {
    UXEvent* e = new UXEvent();
    e.kind = (u8)kind;
    e.x = (i16)x;
    e.y = (i16)y;
    e.handle = w.handle;
    if (kind == (i32)UXEventMouseDown)
        {
        w.dispatchMouse(e);
        }
    else
        {
        w.dispatchMouseMoved(e);
        }
    }
// the synthetic checks, once the view is scrolled 380: B (document 400..430) shows at 40..70
void synthChecks(UXWindow* w, Marker* a, Marker* b)
    {
    i32 bc = b.clicks;
    i32 ac = a.clicks;
    synth(w, (i32)UXEventMouseDown, (i32)100, (i32)55);
    ck((u8*)"a synthetic press through UXWindow.dispatchMouse where B shows reaches B", b.clicks == bc + (i32)1 && a.clicks == ac);
    ck((u8*)"...at the same place in B as a real one (15 down)", b.localY == (i32)15);
    i32 bh = b.hovers;
    synth(w, (i32)UXEventMouseMoved, (i32)100, (i32)55);
    ck((u8*)"a synthetic move there hovers B", b.hovers == bh + (i32)1);
    }
Marker* marker(i32 r, i32 g, i32 b)
    {
    Marker* m = new Marker();
    m.r = r;
    m.g = g;
    m.b = b;
    m.clicks = (i32)0;
    return m;
    }
bool near(UXImage* im, i32 x, i32 y, i32 r, i32 g, i32 b)
    {
    u32 v = im.px[y * im.w + x];
    i32 dr = (i32)((v >> (u32)16) & (u32)255) - r;
    i32 dg = (i32)((v >> (u32)8) & (u32)255) - g;
    i32 db = (i32)(v & (u32)255) - b;
    return dr * dr + dg * dg + db * db < (i32)300;
    }

UXWindow* gWin;
UXScrollView* gSv;
Marker* gA;
Marker* gB;
UXButton* gBtn;
void afterScroll(void)
    {
    i32 h = gWin.handle;
    UXImage* shot = gWin.snapshot((UXRect*)0);
    Stdio.printf("  (scrolled to %d of %d)\n", gSv.scrollPx(), gSv.maxScroll());
    ck((u8*)"scrolling from the app moves the container, and the offset reads back from it", gSv.scrollPx() == (i32)380);
    ux_ios_test_tap_doc(h, (i32)gSv.index, (i32)100, (i32)55);
    ck((u8*)"after the scroll, a tap where B shows reaches B", gB.clicks == (i32)1 && gA.clicks == (i32)1);
    ck((u8*)"...at 15 down in B", gB.localY == (i32)15);
    synthChecks(gWin, gA, gB);
    ck((u8*)"the picture shows B where the scroll put it", shot != (UXImage*)0 && near(shot, (i32)100, (i32)55, (i32)20, (i32)90, (i32)220));
    ck((u8*)"...and the native button scrolled with it", shot != (UXImage*)0 && !near(shot, (i32)90, (i32)134, (i32)235, (i32)235, (i32)240));
    ck((u8*)"...and nothing of the document past the container", shot != (UXImage*)0 && near(shot, (i32)100, (i32)200, (i32)255, (i32)255, (i32)255));
    Stdio.printf(gFails == (i32)0 ? "PASS: an iOS scroll view is a UIScrollView -- it owns the offset, taps land where they show, controls scroll with it\n" : "FAIL: %d\n", gFails);
    ux_ios_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void checks(void)
    {
    i32 h = gWin.handle;
    ck((u8*)"the scroll view is a UIScrollView", ux_ios_test_scroll_native(h, (i32)gSv.index) != (i32)0);
    ck((u8*)"...which owns the offset", gDriver.scrollsNatively());
    ck((u8*)"the native button inside it is in its document", ux_ios_test_in_scroll_doc(h, (i32)gBtn.index, (i32)gSv.index) != (i32)0);
    ux_ios_test_tap_doc(h, (i32)gSv.index, (i32)100, (i32)75); // A at document y 40..70, the document at y 20
    ck((u8*)"a tap on A reaches A", gA.clicks == (i32)1 && gB.clicks == (i32)0);
    gSv.scrollTo((i16)380);
    gWin.displayAll();
    ux_ios_test_call_later((pointer)&afterScroll, (i32)300);
    }
void testBody(void)
    {
    gFails = (i32)0;
    ux_ios_test_watchdog((i32)30000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    gWin = new UXWindow();
    gWin.open((u8*)"scroll", UXGeom.make((i16)0, (i16)0, (i16)300, (i16)240), new Back());
    app.addWindow(gWin);
    gSv = new UXScrollView();
    gWin.contentView.addSubview(gSv, UXGeom.make((i16)20, (i16)20, (i16)200, (i16)150));
    Page* page = new Page();
    gSv.document().addSubview(page, UXGeom.make((i16)0, (i16)0, (i16)200, (i16)600));
    gA = marker((i32)230, (i32)20, (i32)20);
    gB = marker((i32)20, (i32)90, (i32)220);
    page.addSubview(gA, UXGeom.make((i16)0, (i16)40, (i16)180, (i16)30));
    page.addSubview(gB, UXGeom.make((i16)0, (i16)400, (i16)180, (i16)30));
    gBtn = new UXButton();
    gBtn.setTitle((u8*)"Inside");
    page.addSubview(gBtn, UXGeom.make((i16)20, (i16)480, (i16)100, (i16)28));
    gSv.setDocumentHeight((i32)600);
    gWin.displayAll();
    ux_ios_test_call_later((pointer)&checks, (i32)800);
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
    }
