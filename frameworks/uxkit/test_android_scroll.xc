// test_android_scroll.xc — a scroll view on Android is a ScrollView (the android-scroll gate).
//
// The gtk-scroll scene, with real input: a scroll view 150 tall over a 600-tall document, two drawn
// markers, A near the top and B far down, and a native button below B.  The app logs where on the
// screen it wants a tap or a swipe, and the GATE makes it (adb input).  Checked: the container is a
// ScrollView that owns the offset, with the button in its document; a real tap on A reaches A;
// scrolling from the app moves the container and reads back from it, and the picture shows B and the
// button where the scroll put them; a real tap where B now shows reaches B; and a real swipe scrolls
// the ScrollView by itself, which the toolkit reads back.
#import <Stdio.xc>
#import "UXAndroidDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
extern i32 ux_and_test_scroll_native(i32 handle, i32 node);
extern i32 ux_and_test_in_scroll_doc(i32 handle, i32 node, i32 scrollNode);
extern void ux_and_test_doc_screen(i32 handle, i32 node, i32 x, i32 y, i32* sx, i32* sy);
extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);

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
    void drawRect(UXGraphics* gr, UXRect dirty)
        {
        gr.fillRectRGB(self.bounds(), r, g, b);
        }
    void mouseDown(UXEvent* e)
        {
        clicks = clicks + (i32)1;
        }
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
i32 gStep;
i32 gWaited;
i32 gLastPx;
i32 gStill;
// a tap at a point of the window's content (the toolkit's coordinates, the document unscrolled):
// where on the screen that point of the document is now
void askTap(u8* tag, i32 x, i32 y)
    {
    i32 sx = (i32)0;
    i32 sy = (i32)0;
    ux_and_test_doc_screen(gWin.handle, (i32)gSv.index, x, y, &sx, &sy);
    Stdio.printf("%s %d %d\n", tag, sx, sy);
    }
void finish(void)
    {
    ux_and_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void step(void)
    {
    if (gStep == (i32)1)
        {
        if (gA.clicks == (i32)0 && gWaited < (i32)150)
            {
            gWaited = gWaited + (i32)1;
            ux_and_test_call_later((pointer)&step, (i32)100);
            return;
            }
        ck((u8*)"a real tap on A reaches A", gA.clicks == (i32)1 && gB.clicks == (i32)0);
        gSv.scrollTo((i16)380);
        gWin.displayAll();
        gStep = (i32)2;
        ux_and_test_call_later((pointer)&step, (i32)400);
        return;
        }
    if (gStep == (i32)2)
        {
        Stdio.printf("  (scrolled to %d of %d)\n", gSv.scrollPx(), gSv.maxScroll());
        ck((u8*)"scrolling from the app moves the container, and the offset reads back from it", gSv.scrollPx() == (i32)380);
        UXImage* shot = gWin.snapshot((UXRect*)0);
        ck((u8*)"the picture shows B where the scroll put it", shot != (UXImage*)0 && near(shot, (i32)100, (i32)55, (i32)20, (i32)90, (i32)220));
        ck((u8*)"...and the native button scrolled with it", shot != (UXImage*)0 && !near(shot, (i32)90, (i32)134, (i32)235, (i32)235, (i32)240));
        gStep = (i32)3;
        gWaited = (i32)0;
        askTap((u8*)"TAP2", (i32)120, (i32)435); // B's middle: 400..430 in the document
        ux_and_test_call_later((pointer)&step, (i32)100);
        return;
        }
    if (gStep == (i32)3)
        {
        if (gB.clicks == (i32)0 && gWaited < (i32)150)
            {
            gWaited = gWaited + (i32)1;
            ux_and_test_call_later((pointer)&step, (i32)100);
            return;
            }
        ck((u8*)"after the scroll, a real tap where B shows reaches B", gB.clicks == (i32)1 && gA.clicks == (i32)1);
        gSv.scrollTo((i16)0);
        gWin.displayAll();
        gStep = (i32)4;
        gWaited = (i32)0;
        i32 sx = (i32)0;
        i32 sy0 = (i32)0;
        i32 sy1 = (i32)0;
        ux_and_test_doc_screen(gWin.handle, (i32)gSv.index, (i32)120, (i32)150, &sx, &sy0);
        ux_and_test_doc_screen(gWin.handle, (i32)gSv.index, (i32)120, (i32)50, &sx, &sy1);
        Stdio.printf("SWIPE %d %d %d %d\n", sx, sy0, sx, sy1); // a finger dragged 100 up the document
        ux_and_test_call_later((pointer)&step, (i32)100);
        return;
        }
    // wait for the swipe to land and the scroll (with its fling) to settle: moved, and still for 0.5 s
    i32 now = gSv.scrollPx();
    if (gWaited < (i32)150 && (now == (i32)0 || now != gLastPx || gStill < (i32)5))
        {
        gStill = now == gLastPx && now != (i32)0 ? gStill + (i32)1 : (i32)0;
        gLastPx = now;
        gWaited = gWaited + (i32)1;
        ux_and_test_call_later((pointer)&step, (i32)100);
        return;
        }
    Stdio.printf("  (after the swipe: scrolled to %d)\n", gSv.scrollPx());
    ck((u8*)"a real swipe scrolls the ScrollView, and the toolkit reads it back", gSv.scrollPx() > (i32)30);
    Stdio.printf(gFails == (i32)0 ? "PASS: an Android scroll view is a ScrollView -- it owns the offset, real taps land where they show, a real swipe scrolls it\n" : "FAIL: %d\n", gFails);
    ux_and_test_call_later((pointer)&finish, (i32)1000);
    }
void checks(void)
    {
    i32 h = gWin.handle;
    ck((u8*)"the scroll view is a ScrollView", ux_and_test_scroll_native(h, (i32)gSv.index) != (i32)0);
    ck((u8*)"...which owns the offset", gDriver.scrollsNatively());
    ck((u8*)"the native button inside it is in its document", ux_and_test_in_scroll_doc(h, (i32)gBtn.index, (i32)gSv.index) != (i32)0);
    gStep = (i32)1;
    gWaited = (i32)0;
    askTap((u8*)"TAP1", (i32)120, (i32)75); // A's middle: the document at (20, 20), A at 40..70 in it
    ux_and_test_call_later((pointer)&step, (i32)100);
    }
void testBody(void)
    {
    gFails = (i32)0;
    ux_and_test_watchdog((i32)90000, (i32)2);
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
    ux_and_test_call_later((pointer)&checks, (i32)1500);
    }

void main(void)
    {
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
    }
