// test_snapshot.xc — UXWindow.snapshot: the window's content as on screen, as an image (the
// *-snapshot gates, one per backend; built with -D SNAP_<BACKEND>).
//
// The window holds what a client's does: an app-drawn backdrop (green), a GL view cleared to a
// colour only this test uses (blue), a 2-D view after it in the tree and so drawn over it (red),
// and a native button.  Checked: the whole snapshot is the content's size; each of those is in it
// where it is on screen, the red OVER the blue; the button is there; a region is the same pixels as
// that part of the whole; a region hanging off the content is clipped to it, and one wholly off it
// is null.  It also times a whole-window snapshot.
#import <Stdio.xc>
#if SNAP_APPKIT
#import "UXAppKitDriver.xc"
#import "demo_autoquit.xc"
#endif
#if SNAP_WIN32
#import "UXWin32Driver.xc"
#endif
#if SNAP_GTK
#import "UXGtkDriver.xc"
void ux_gtk_wait_allocated(i32 handle);
#endif
#if SNAP_WEB
#import "UXWebDriver.xc"
// on wasm the GL entry points are imports the renderer declares, not pointers from glProc
void glClearColor(float r, float g, float b, float a);
void glClear(u32 mask);
void glFinish(void);
#endif
#if SNAP_IOS
#import "UXIosDriver.xc"
#endif
#if SNAP_ANDROID
#import "UXAndroidDriver.xc"
#endif
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXFileIO.xc"

typedef void ClearColorFn(float r, float g, float b, float a);
typedef void ClearFn(u32 mask);
typedef void FinishFn(void);
u8* getenv(u8* name);

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

// The backdrop leaves the map's rectangle unpainted: where GL is a plane of its own under the 2-D
// views (GTK, the web), a parent painted across it would hide it on screen as well.
class Backdrop : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRectRGB(UXGeom.make((i16)0, (i16)0, b.w, (i16)20), (i32)20, (i32)160, (i32)60);
        g.fillRectRGB(UXGeom.make((i16)0, (i16)140, b.w, (i16)(b.h - (i16)140)), (i32)20, (i32)160, (i32)60);
        g.fillRectRGB(UXGeom.make((i16)0, (i16)20, (i16)20, (i16)120), (i32)20, (i32)160, (i32)60);
        g.fillRectRGB(UXGeom.make((i16)220, (i16)20, (i16)(b.w - (i16)220), (i16)120), (i32)20, (i32)160, (i32)60);
        }
    }
// The GL view's software fallback, for a backend with no GL: the same blue the GL frame is cleared
// to, so the picture is the same either way.
class MapView : UXGLView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)64, (i32)128, (i32)191);
        }
    }
class OverView : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)230, (i32)20, (i32)20);
        }
    }

UXWindow* gWin;
MapView* gMap;
UXButton* gButton;

// the window's content, built and painted once (the GL frame cleared to the test's blue)
void buildWindow(i32 x, i32 y)
    {
    UXView* back = new Backdrop();
    gWin = new UXWindow();
    gWin.open((u8*)"snapshot", UXGeom.make((i16)x, (i16)y, (i16)360, (i16)200), back);
    if (gApp != (UXApplication*)0)
        {
        gApp.addWindow(gWin);
        }
    gMap = new MapView();
    back.addSubview(gMap, UXGeom.make((i16)20, (i16)20, (i16)200, (i16)120));
    back.addSubview(new OverView(), UXGeom.make((i16)60, (i16)50, (i16)40, (i16)30)); // after the map: over it
    gButton = new UXButton();
    gButton.setTitle((u8*)"Record");
    back.addSubview(gButton, UXGeom.make((i16)240, (i16)20, (i16)100, (i16)32));
    gWin.displayAll();
#if SNAP_GTK
    ux_gtk_wait_allocated(gWin.handle); // the frame clock: a headless gate has no window manager
#endif
#if SNAP_WEB
    if (gMap.makeGL())
        {
        glClearColor(0.25, 0.5, 0.75, 1.0);
        glClear((u32)$4000);
        glFinish();
        gMap.presentGL();
        }
#else
    if (gMap.makeGL())
        {
        ClearColorFn* cc = (ClearColorFn*)gDriver.glProc((u8*)"glClearColor");
        ClearFn* cl = (ClearFn*)gDriver.glProc((u8*)"glClear");
        FinishFn* fin = (FinishFn*)gDriver.glProc((u8*)"glFinish");
        cc(0.25, 0.5, 0.75, 1.0);
        cl((u32)$4000); // GL_COLOR_BUFFER_BIT
        fin();
        gMap.presentGL();
        }
#endif
    gWin.displayAll();
    }

bool near(UXImage* im, i32 x, i32 y, i32 r, i32 g, i32 b)
    {
    u32 v = im.px[y * im.w + x];
    i32 dr = (i32)((v >> (u32)16) & (u32)255) - r;
    i32 dg = (i32)((v >> (u32)8) & (u32)255) - g;
    i32 db = (i32)(v & (u32)255) - b;
    return dr * dr + dg * dg + db * db < (i32)300;
    }
void show(UXImage* im, i32 x, i32 y)
    {
    u32 v = im.px[y * im.w + x];
    Stdio.printf("  (%d,%d) = %d %d %d\n", x, y, (i32)((v >> (u32)16) & (u32)255), (i32)((v >> (u32)8) & (u32)255), (i32)(v & (u32)255));
    }
// is the region (x, y, w, h) of whole the same pixels as part?
bool sameAs(UXImage* whole, UXImage* part, i32 x, i32 y)
    {
    i32 diff = (i32)0;
    for (i32 j = (i32)0; j < part.h; j = j + (i32)1)
        {
        for (i32 i = (i32)0; i < part.w; i = i + (i32)1)
            {
            if (part.px[j * part.w + i] != whole.px[(y + j) * whole.w + x + i])
                {
                diff = diff + (i32)1;
                }
            }
        }
    if (diff != (i32)0)
        {
        Stdio.printf("  (%d of %d pixels differ)\n", diff, part.w * part.h);
        }
    return diff == (i32)0;
    }

i64 nowUs(void)
    {
    return (i64)gDriver.nowMs() * (i64)1000;
    }

void snapChecks(void)
    {
    UXImage* all = gWin.snapshot((UXRect*)0);
    i32 cw = (i32)0;
    i32 ch = (i32)0;
    gDriver.windowContentGeometry(gWin.handle, &cw, &ch);
    ck((u8*)"the window snapshots", all != (UXImage*)0);
    if (all == (UXImage*)0)
        {
        return;
        }
    Stdio.printf("  (content %dx%d, snapshot %dx%d, GL %s)\n", cw, ch, all.w, all.h, gMap.glContext() != (pointer)0 ? (u8*)"on" : (u8*)"off");
#if SNAP_APPKIT || SNAP_WIN32 || SNAP_GTK
    // UX_SNAP_SAVE=<file>: the whole snapshot as a PPM, for a person to look at
    u8* save = getenv((u8*)"UX_SNAP_SAVE");
    if (save != (u8*)0)
        {
        UXData* ppm = UXData.fromString((u8*)"P6\n360 200\n255\n");
        for (i32 i = (i32)0; i < all.w * all.h; i = i + (i32)1)
            {
            u32 v = all.px[i];
            ppm.appendByte((u8)((v >> (u32)16) & (u32)255));
            ppm.appendByte((u8)((v >> (u32)8) & (u32)255));
            ppm.appendByte((u8)(v & (u32)255));
            }
        UXFileIO.write(save, ppm);
        }
#endif
    show(all, (i32)10, (i32)170);
    show(all, (i32)30, (i32)30);
    show(all, (i32)70, (i32)60);
    ck((u8*)"...the whole content, at its size", all.w == cw && all.h == ch);
    ck((u8*)"the app-drawn backdrop is in it", near(all, (i32)10, (i32)170, (i32)20, (i32)160, (i32)60));
    ck((u8*)"the map is in it", near(all, (i32)30, (i32)30, (i32)64, (i32)128, (i32)191));
    ck((u8*)"the 2-D view after the map is in it, over the map", near(all, (i32)70, (i32)60, (i32)230, (i32)20, (i32)20));
    // the button: across its frame, pixels that are neither the backdrop nor black (a face where the
    // platform paints one, the title's ink where it does not, as on iOS); a picture that is merely
    // not the backdrop -- all black, say -- does not count
    i32 drawn = (i32)0;
    for (i32 x = (i32)242; x < (i32)338; x = x + (i32)1)
        {
        u32 v = all.px[(i32)36 * all.w + x];
        u32 sum = ((v >> (u32)16) & (u32)255) + ((v >> (u32)8) & (u32)255) + (v & (u32)255);
        if (!near(all, x, (i32)36, (i32)20, (i32)160, (i32)60) && sum > (u32)90)
            {
            drawn = drawn + (i32)1;
            }
        }
    Stdio.printf("  (button row: %d of 96 pixels drawn)\n", drawn);
    ck((u8*)"the native button is in it", drawn > (i32)8);

    UXRect r = UXGeom.make((i16)20, (i16)20, (i16)200, (i16)120);
    UXImage* map = gWin.snapshot(&r);
    ck((u8*)"a region is that part of the window, pixel for pixel", map != (UXImage*)0 && map.w == (i32)200 && map.h == (i32)120 && sameAs(all, map, (i32)20, (i32)20));
    UXRect off = UXGeom.make((i16)-10, (i16)-10, (i16)30, (i16)30);
    UXImage* corner = gWin.snapshot(&off);
    ck((u8*)"a region off the edge is clipped to the content", corner != (UXImage*)0 && corner.w == (i32)20 && corner.h == (i32)20 && sameAs(all, corner, (i32)0, (i32)0));
    UXRect away = UXGeom.make((i16)(cw + (i32)10), (i16)0, (i16)30, (i16)30);
    ck((u8*)"a region wholly off it is null", gWin.snapshot(&away) == (UXImage*)0);

    i32 t0 = gDriver.nowMs();
    for (i32 i = (i32)0; i < (i32)10; i = i + (i32)1)
        {
        gWin.snapshot((UXRect*)0);
        }
    Stdio.printf("  (a whole-window snapshot takes %d ms)\n", (gDriver.nowMs() - t0) / (i32)10);
    }

void verdict(void)
    {
    Stdio.printf(gFails == (i32)0 ? "PASS: UXWindow.snapshot -- the window as on screen, GL and native controls included, whole or a region\n" : "FAIL: %d\n", gFails);
    }

#if SNAP_IOS
extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_test_call_later(pointer fn, i32 ms);
void mobileRun(void)
    {
    snapChecks();
    verdict();
    ux_ios_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void testBody(void)
    {
    ux_ios_test_watchdog((i32)30000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    buildWindow((i32)0, (i32)0);
    ux_ios_test_call_later((pointer)&mobileRun, (i32)1000);
    }
void main(void)
    {
    gFails = (i32)0;
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
    }
#elif SNAP_ANDROID
extern void ux_and_set_entry(pointer fn);
extern void ux_and_shell_run(void);
extern void ux_and_quit(i32 rc);
extern void ux_and_test_watchdog(i32 ms, i32 rc);
extern void ux_and_test_call_later(pointer fn, i32 ms);
void mobileQuit(void)
    {
    ux_and_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }
void mobileRun(void)
    {
    snapChecks();
    verdict();
    ux_and_test_call_later((pointer)&mobileQuit, (i32)1000);
    }
void testBody(void)
    {
    ux_and_test_watchdog((i32)30000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    buildWindow((i32)0, (i32)0);
    ux_and_test_call_later((pointer)&mobileRun, (i32)1500);
    }
void main(void)
    {
    gFails = (i32)0;
    gDriver = new UXAndroidDriver();
    ux_and_set_entry((pointer)&testBody);
    ux_and_shell_run();
    }
#else
class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        buildWindow((i32)60, (i32)60);
        snapChecks();
        app.stop();
        return (i32)0;
        }
    }
void main(void)
    {
    gFails = (i32)0;
#if SNAP_APPKIT
    UXAppKitDriver* d = new UXAppKitDriver();
    d.setInteractive(getenv((u8*)"UX_SNAP_HEADLESS") == (u8*)0);
#endif
#if SNAP_WIN32
    UXWin32Driver* d = new UXWin32Driver();
#endif
#if SNAP_GTK
    UXGtkDriver* d = new UXGtkDriver();
#endif
#if SNAP_WEB
    UXWebDriver* d = new UXWebDriver();
#endif
    gDriver = d;
    UXApplication* app = new UXApplication();
#if SNAP_APPKIT
    d.attachApp(app);
#else
    app.setDriver((UXViewDriver*)d);
#endif
    gApp = app;
    app.setDelegate(new Delegate());
    app.run();
    verdict();
    }
#endif
