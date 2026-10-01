// demo_appkit_gl.xc — the AppKit GL seam, exercised for real.
//
// The neutral gate (test_glseam) pins the ABI and the frozen default state.  This one is the
// other half, and it needs a live window because what it checks -- that a surface exists, that
// a context binds to it, that the swap runs, that both go away clean -- only exists once there
// is a window server.  Nothing here is AppKit-aware: the app makes a UXGLView, calls makeGL,
// and reads the answers back through the toolkit.
//
// It runs in TWO shapes, because the seam's two promises are made in different places:
//
//   live (default)     a real window and AppKit's loop.  The surface, the context, the swap,
//                      destroy-and-recreate, and a clean exit -- a GL client that leaks its
//                      context dies on the way out, so the exit status is itself a check.
//
//   UX_GL_HEADLESS=1   no window at all, which is how every CI gate runs.  There is no surface
//                      and so no context, and the view must still be PAINTED -- by drawRect,
//                      through the same neutral path a backend with no GL uses.  This is the
//                      half that matters for the software path, and it is also the only half
//                      where a paint can be observed synchronously: AppKit paints on its own
//                      cycle, so the live half can assert the decision but not the pixels.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"
#import "demo_autoquit.xc"

u8* getenv(u8* name);

i32 gFails = 0;
void ck(bool ok, u8* what)
    {
    if (!ok)
        {
        Stdio.printf("  no: %s\n", what);
        gFails = gFails + 1;
        }
    }

// A GL view that also draws.  The fallback is what a backend without GL gets, so the view has to
// keep one, and the seam's promise is that only ONE of the two ever runs.
class MapView : UXGLView
    {
    i32 painted;
    void init(void)
        {
        super.init();
        painted = 0;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        painted = painted + 1;
        g.fillRect(UXGeom.make((i16)0, (i16)0, (i16)200, (i16)120), (i32)5);
        }
    }

    class Controller : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    UXWindow* win;
    MapView* map;
    UXLabel* overlay;

    // ── live: the surface and the context ────────────────────────────────────
    void checkLive(void)
        {
        MapView* v = map;
        ck(v.kind() == UXKindGLView, "a GL view is UXKindGLView");
        ck(v.ownsGL() == false, "no context before makeGL");
        ck(v.glContext() == (pointer)0, "no context pointer before makeGL");
        ck(v.glKind() == (i32)UX_GL_GL33, "glKind() is GL33 on AppKit, not NONE");
        ck(!gDriver.compositesWithGL(), "AppKit has no GL plane: the driver paints the frame into the 2-D pass");

        bool made = v.makeGL();
        ck(made, "makeGL() found a surface to bind to");
        ck(v.ownsGL(), "the view owns a context after makeGL");
        ck(v.glContext() != (pointer)0, "the context token is non-zero");

        pointer first = v.glContext();
        ck(v.makeGL(), "makeGL() again is idempotent");
        ck(v.glContext() == first, "and does not make a second context");

        // A real swap of a real drawable: a crash here is the whole point of gating it.
        v.presentGL();
        v.presentGL();
        Stdio.printf("  presentGL x2 with a live context\n");

        // The skip is the seam's rule -- both renderers in one frame is the bug it exists to
        // prevent.  The DECISION is visible here; that the pixels stop coming is the headless
        // half's assertion, since AppKit paints on its own cycle and not inside this call.
        v.setNeedsDisplay();
        win.displayAll();
        ck(v.ownsGL(), "a paint does not take the context away");

        v.destroyGL();
        ck(v.ownsGL() == false, "destroyGL() releases");
        ck(v.glContext() == (pointer)0, "the token is cleared");

        // Made a second time -- the classic bug is that the surface was dropped with the first
        // context, so the second one binds to nothing.
        ck(v.makeGL(), "a context can be made again after destroyGL");
        v.presentGL();

        ck(overlay.isHidden() == false, "the 2D sibling over the map is still there");
        Stdio.printf("  painted=%d, glKind=%d\n", v.painted, v.glKind());
        }

    // ── headless: the software fallback, painted synchronously ───────────────
    void checkHeadless(void)
        {
        MapView* v = map;
        ck(v.glKind() == (i32)UX_GL_GL33, "the backend still reports its GL");
        ck(!gDriver.compositesWithGL(), "...and answers the same with no window shown");
        ck(v.makeGL() == false, "but with no window there is no surface to bind to");
        ck(v.ownsGL() == false, "so the view owns no context");
        ck(v.glContext() == (pointer)0, "and the token is null");

        win.displayAll();
        i32 first = v.painted;
        ck(first > (i32)0, "the fallback painted through drawRect");
        win.displayAll();
        ck(v.painted > first, "and paints again -- drawRect is the renderer here");

        // presentGL on a view with no context must be inert, not a crash: that is what a GL app
        // does when it runs on a box with no display, and it is the common case in CI.
        v.presentGL();
        v.destroyGL();
        ck(v.ownsGL() == false, "present and destroy with no context are inert");
        Stdio.printf("  painted=%d (fallback), glKind=%d\n", v.painted, v.glKind());
        }

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        bool headless = getenv((u8*)"UX_GL_HEADLESS") != (u8*)0;

        UXView* canvas = new UXView();
        win = new UXWindow();
        win.open((u8*)"UXKit GL seam", UXGeom.make((i16)160, (i16)160, (i16)340, (i16)260), canvas);

        map = new MapView();
        canvas.addSubview(map, UXGeom.make((i16)20, (i16)20, (i16)300, (i16)180));
        overlay = new UXLabel();
        overlay.setText((u8*)"2D over the map");
        canvas.addSubview(overlay, UXGeom.make((i16)28, (i16)200, (i16)284, (i16)18));

        win.displayAll();
        if (headless)
            {
            self.checkHeadless();
            app.stop(); // start-up is enough; there is nothing to wait for
            }
        else
            {
            self.checkLive();
            Stdio.printf("demo up\n");
            }
        return (i32)0;
        }
    }

    void
    main(void)
    {
    bool headless = getenv((u8*)"UX_GL_HEADLESS") != (u8*)0;
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(!headless);
    Controller* c = new Controller();
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(c);
    if (!headless)
        {
        uxAutoQuit();
        }
    app.run();
    if (gFails == 0)
        {
        if (headless)
            {
            Stdio.printf("PASS: AppKit GL seam (headless) — no surface, and the fallback still paints\n");
            }
        else
            {
            Stdio.printf("PASS: AppKit GL seam — surface binds, the swap runs, both go away clean\n");
            }
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
