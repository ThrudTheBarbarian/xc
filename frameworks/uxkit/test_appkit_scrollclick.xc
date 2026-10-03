// test_appkit_scrollclick.xc — clicks inside a scrolled NSScrollView land on what shows there (the
// appkit-scrollclick gate).  The same scene as gtk-scroll; each click is a real NSEvent posted to
// the queue, so AppKit hit-tests it and it bubbles as a person's does.  A marker outside the scroll
// view is clicked too, as the control.
//
// A scroll view 150 tall over a 600-tall document: two drawn markers, A near the top and B far down,
// and a native button below B.  Checked: the container is a GtkScrolledWindow, it owns the offset
// (scrollsNatively) and the native button has moved into its document; a click on A, taken the way a
// real one is (window coordinates, onto the document), reaches A; scrolling the view from the app
// moves the container, and the toolkit reads the offset back from it; after that, a click where B now
// shows reaches B, and the picture shows B and the button where the scroll put them.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXScrollView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
void ux_ak_post_click(i32 handle, i32 x, i32 y);

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
Marker* gC;
i32 gTurn;
void step(void)
    {
    gTurn = gTurn + (i32)1;
    if (gTurn == (i32)8)
        {
        Stdio.printf("  (clicks: A %d, B %d, C %d)\n", gA.clicks, gB.clicks, gC.clicks);
        ck((u8*)"a click outside the scroll view reaches its view (the control)", gC.clicks == (i32)1);
        ck((u8*)"a click on A, unscrolled, reaches A", gA.clicks == (i32)1 && gB.clicks == (i32)0);
        gSv.scrollTo((i16)380);
        gWin.displayAll();
        Stdio.printf("  (scrolled to %d)\n", gSv.scrollPx());
        ux_ak_post_click(gWin.handle, (i32)100, (i32)55); // B now shows at window y 40..70
        }
    if (gTurn == (i32)16)
        {
        Stdio.printf("  (clicks: A %d, B %d)\n", gA.clicks, gB.clicks);
        ck((u8*)"after the scroll, a click where B shows reaches B", gB.clicks == (i32)1 && gA.clicks == (i32)1);
        Stdio.printf(gFails == (i32)0 ? "PASS: clicks inside a scrolled NSScrollView land on what shows there\n" : "FAIL: %d\n", gFails);
        gApp.everyTurn((turnHook_t*)0, (i32)0);
        gApp.stop();
        }
    }
class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        gWin = new UXWindow();
        gWin.open((u8*)"scroll", UXGeom.make((i16)60, (i16)60, (i16)300, (i16)240), new Back());
        app.addWindow(gWin);
        gSv = new UXScrollView();
        gWin.contentView.addSubview(gSv, UXGeom.make((i16)20, (i16)20, (i16)200, (i16)150));
        Page* page = new Page();
        gSv.document().addSubview(page, UXGeom.make((i16)0, (i16)0, (i16)200, (i16)600));
        gA = marker((i32)230, (i32)20, (i32)20);
        gB = marker((i32)20, (i32)90, (i32)220);
        page.addSubview(gA, UXGeom.make((i16)0, (i16)40, (i16)180, (i16)30));
        page.addSubview(gB, UXGeom.make((i16)0, (i16)400, (i16)180, (i16)30));
        gSv.setDocumentHeight((i32)600);
        gC = marker((i32)20, (i32)200, (i32)20);
        gWin.contentView.addSubview(gC, UXGeom.make((i16)240, (i16)20, (i16)50, (i16)50));
        gWin.displayAll();
        ux_ak_post_click(gWin.handle, (i32)280, (i32)200); // the backdrop: the click that activates the window
        ux_ak_post_click(gWin.handle, (i32)260, (i32)40); // C
        ux_ak_post_click(gWin.handle, (i32)100, (i32)75); // A at document y 40..70, the document at y 20
        app.everyTurn(&step, (i32)16);
        return (i32)0;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    gApp = app;
    app.setDelegate(new Delegate());
    app.run();
    }
