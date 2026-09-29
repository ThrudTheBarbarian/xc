// demo_appkit_surface.xc — a view that paints in its OWN surface, over a GL surface (AppKit).
//
// A UXView with setOwnSurface(true) realises as a real NSView subview (UXSurfaceView) whose
// drawRect draws the view's SUBTREE; being a real subview it sits ABOVE the GL surface, which the
// driver keeps at the BOTTOM of the stack.  That is the whole reason the kind exists: a view's own
// paint is drawn before its subviews, so a plain inline paint is UNDER a GL surface and only a real
// subview is over it.  A backend that cannot make one declines and draws the view inline.
//
// The gate checks the two halves of that promise in the two shapes it is made:
//   live      a real window.  The surface is realised natively, it sits ABOVE the GL surface, and
//             its ink is in the window's picture.  The harness GL fallback is empty, so the picture
//             is background plus the surface's ink alone -- hiding the view takes the ink back out,
//             which proves the marks really were the view's and not the map's.
//   headless  no window and no surface, which is how CI runs and how a backend that cannot make one
//             behaves: the view must still be PAINTED, inline through drawRect like any UXView.
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
// From libUXAppKit.m -- the shim's own surface tooling, not part of the drawing seam.
i32 ux_ak_gl_grab_window(pointer peer, u8* path);
i32 ux_ak_gl_grab_marks(void);
i32 ux_ak_surface_over_gl(pointer surfPeer, pointer glPeer);

i32 gFails = 0;
void ck(bool ok, u8* what)
    {
    if (!ok)
        {
        Stdio.printf("  no: %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

// The GL view: it owns a surface the app renders into, and keeps a software fallback for the
// backends (and the headless run) that cannot give it a context.  The fallback is EMPTY, like the
// frame harness: in a window grab it is drawn and the map's composited contents are not, so an
// empty fallback leaves the picture to the surface ink on top.
class MapView : UXGLView
    {
    i32 painted;
    void init(void) { super.init(); painted = (i32)0; }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        painted = painted + (i32)1;
        }
    }

// The ink view: a plain view that asks to paint in its OWN surface.  On AppKit that puts a real
// subview over the map; everywhere else it is an ordinary drawn view.
class InkView : UXView
    {
    i32 painted;
    void init(void) { super.init(); painted = (i32)0; }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        painted = painted + (i32)1;
        g.fillRect(UXGeom.make((i16)0, (i16)0, (i16)120, (i16)48), (i32)8); // a solid ink block
        }
    }

class Controller : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    UXWindow* win;
    MapView* map;
    InkView* ink;

    void checkLive(void)
        {
        ck(ink.kind() == UXKindSurface, "the ink view reports UXKindSurface");
        ck(ink.paintsInOwnSurface(), "and says it paints in its own surface");
        ck(map.makeGL(), "the map bound a GL context to its surface");
        // The structural promise: the surface is a real subview ABOVE the composited GL.
        ck(ux_ak_surface_over_gl((pointer)ink, (pointer)map) == (i32)1, "the ink surface sits OVER the GL surface");

        ux_ak_gl_grab_window((pointer)map, (u8*)"/tmp/surface_over_gl.png");
        i32 shown = ux_ak_gl_grab_marks();
        ck(shown > (i32)0, "the window picture holds the ink");
        // Hide the view: the surface subview goes with it, and the ink leaves the picture -- so the
        // marks above were really the view's, not the map's fallback.
        ink.setHidden(true);
        win.displayAll();
        ux_ak_gl_grab_window((pointer)map, (u8*)"/tmp/surface_over_gl_hidden.png");
        i32 gone = ux_ak_gl_grab_marks();
        ck(gone < shown, "hiding the view takes its ink back out of the picture");
        ink.setHidden(false);
        win.displayAll();
        Stdio.printf("  ink painted=%d, grab shown=%d hidden=%d\n", ink.painted, shown, gone);
        }

    void checkHeadless(void)
        {
        ck(ink.kind() == UXKindSurface, "the ink view still reports UXKindSurface");
        // No window, so realizeTree never ran and no surface was made: the decline.
        ck(ux_ak_surface_over_gl((pointer)ink, (pointer)map) == (i32)-1, "there is no surface to be over anything");
        win.displayAll();
        i32 first = ink.painted;
        ck(first > (i32)0, "the view painted inline through drawRect");
        win.displayAll();
        ck(ink.painted > first, "and paints again -- drawRect is the renderer here");
        Stdio.printf("  ink painted=%d (inline), no surface\n", ink.painted);
        }

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        bool headless = getenv((u8*)"UX_GL_HEADLESS") != (u8*)0;

        UXView* canvas = new UXView();
        win = new UXWindow();
        win.open((u8*)"UXKit surface over GL", UXGeom.make((i16)160, (i16)160, (i16)340, (i16)260), canvas);

        map = new MapView();
        canvas.addSubview(map, UXGeom.make((i16)20, (i16)20, (i16)300, (i16)180));
        ink = new InkView();
        ink.setOwnSurface(true); // BEFORE it is attached: the choice becomes the view's kind
        canvas.addSubview(ink, UXGeom.make((i16)60, (i16)60, (i16)120, (i16)48));

        win.displayAll();
        if (headless)
            {
            self.checkHeadless();
            app.stop();
            }
        else
            {
            self.checkLive();
            Stdio.printf("demo up\n");
            }
        return (i32)0;
        }
    }

void main(void)
    {
    bool headless = getenv((u8*)"UX_GL_HEADLESS") != (u8*)0;
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(!headless);
    Controller* c = new Controller();
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(c);
    if (!headless) { uxAutoQuit(); }
    app.run();
    if (gFails == 0)
        {
        if (headless)
            Stdio.printf("PASS: AppKit surface (headless) -- no surface, and the view paints inline\n");
        else
            Stdio.printf("PASS: AppKit surface -- a real subview over the GL surface, and its ink is the picture\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
