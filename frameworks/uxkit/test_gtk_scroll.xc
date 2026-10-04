// test_gtk_scroll.xc — a scroll view on GTK is a GtkScrolledWindow (the gtk-scroll gate).
//
// A scroll view 150 tall over a 600-tall document: two drawn markers, A near the top and B far down,
// and a native button below B.  Checked: the container is a GtkScrolledWindow, it owns the offset
// (scrollsNatively) and the native button has moved into its document; a click on A, taken the way a
// real one is (window coordinates, onto the document), reaches A; scrolling the view from the app
// moves the container, and the toolkit reads the offset back from it; after that, a click where B now
// shows reaches B, and the picture shows B and the button where the scroll put them.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
extern i32 ux_gtk_test_scroll_native(i32 handle, i32 node);
extern i32 ux_gtk_test_in_scroll_doc(i32 handle, i32 node, i32 scrollNode);
extern void ux_gtk_test_click_at(i32 handle, i32 x, i32 y);
void ux_gtk_wait_allocated(i32 handle);

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

void main(void)
    {
    gFails = (i32)0;
    UXGtkDriver* d = new UXGtkDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!d.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display\n");
        return;
        }
    UXApplication* app = new UXApplication();
    app.setDriver((UXViewDriver*)d);
    gApp = app;
    UXWindow* win = new UXWindow();
    win.open((u8*)"scroll", UXGeom.make((i16)60, (i16)60, (i16)300, (i16)240), new Back());
    app.addWindow(win);
    UXScrollView* sv = new UXScrollView();
    win.contentView.addSubview(sv, UXGeom.make((i16)20, (i16)20, (i16)200, (i16)150));
    Page* page = new Page();
    sv.document().addSubview(page, UXGeom.make((i16)0, (i16)0, (i16)200, (i16)600));
    Marker* a = marker((i32)230, (i32)20, (i32)20);  // red, near the top
    Marker* b = marker((i32)20, (i32)90, (i32)220);  // blue, far down
    page.addSubview(a, UXGeom.make((i16)0, (i16)40, (i16)180, (i16)30));
    page.addSubview(b, UXGeom.make((i16)0, (i16)400, (i16)180, (i16)30));
    UXButton* btn = new UXButton();
    btn.setTitle((u8*)"Inside");
    page.addSubview(btn, UXGeom.make((i16)20, (i16)480, (i16)100, (i16)28));
    sv.setDocumentHeight((i32)600);
    win.displayAll();
    ux_gtk_wait_allocated(win.handle);
    win.snapshot((UXRect*)0); // a frame painted: the container's allocation is in place

    i32 h = win.handle;
    ck((u8*)"the scroll view is a GtkScrolledWindow", ux_gtk_test_scroll_native(h, (i32)sv.index) != (i32)0);
    ck((u8*)"...which owns the offset", gDriver.scrollsNatively());
    ck((u8*)"the native button inside it is in its document", ux_gtk_test_in_scroll_doc(h, (i32)btn.index, (i32)sv.index) != (i32)0);

    // A at document y 40..70, the document at window y 20 (scroll view at 20, unscrolled): y 75
    ux_gtk_test_click_at(h, (i32)100, (i32)75);
    ck((u8*)"a click on A reaches A", a.clicks == (i32)1 && b.clicks == (i32)0);

    sv.scrollTo((i16)380);
    win.displayAll();
    UXImage* shot = win.snapshot((UXRect*)0); // ...and a frame with the container scrolled
    Stdio.printf("  (scrolled to %d of %d)\n", sv.scrollPx(), sv.maxScroll());
    ck((u8*)"scrolling from the app moves the container, and the offset reads back from it", sv.scrollPx() == (i32)380);
    // B at document y 400..430 now shows at window y 20 + 20 .. 50
    ux_gtk_test_click_at(h, (i32)100, (i32)55);
    ck((u8*)"after the scroll, a click where B shows reaches B", b.clicks == (i32)1 && a.clicks == (i32)1);
    ck((u8*)"...at 15 down in B", b.localY == (i32)15);
    synthChecks(win, a, b);
    ck((u8*)"the picture shows B where the scroll put it", shot != (UXImage*)0 && near(shot, (i32)100, (i32)55, (i32)20, (i32)90, (i32)220));
    // the button at document y 480..508 now shows at window y 120 .. 148, x 40 .. 140
    ck((u8*)"...and the native button scrolled with it", shot != (UXImage*)0 && !near(shot, (i32)90, (i32)134, (i32)235, (i32)235, (i32)240));
    ck((u8*)"...and nothing of the document past the container", shot != (UXImage*)0 && near(shot, (i32)100, (i32)200, (i32)255, (i32)255, (i32)255));
    Stdio.printf(gFails == (i32)0 ? "PASS: a GTK scroll view is a GtkScrolledWindow -- it owns the offset, clicks land where they show, controls scroll with it\n" : "FAIL: %d\n", gFails);
    }
