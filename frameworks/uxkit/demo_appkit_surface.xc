// demo_appkit_surface.xc — 2-D drawn over a GL map, in ONE surface (AppKit).
//
// The GL view renders offscreen and the driver paints its frame into the window's single 2-D pass,
// in tree order, so a view AFTER it in the tree is drawn over it -- with no native layer, no second
// plane and nothing for the compositor to leave stale.  A view that asks for its own surface
// (setOwnSurface) keeps its kind, and AppKit DECLINES the surface: it is drawn inline, which is
// already over the map.
//
// What the gate checks, at points of the window's own picture:
//   live      the map is IN the window (a point on it is not the window background), the ink is
//             OVER it (a point where the ink covers the map is the ink's colour), and hiding the
//             ink shows the map again at that point -- the order is draw order, nothing else.
//   headless  no window and no GL: the ink paints inline through drawRect, the same as anywhere.
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
// From libUXAppKit.m -- the shim's own picture tooling, not part of the drawing seam.
i32 ux_ak_gl_grab_window(pointer peer, u8* path);
i32 ux_ak_gl_grab_pixel(i32 x, i32 y);

i32 gFails = 0;
void ck(bool ok, u8* what)
    {
    if (!ok)
        {
        Stdio.printf("  no: %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

// The GL view.  Its fallback is EMPTY, so in a run with no GL nothing of it is drawn at all.
class MapView : UXGLView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        }
    }

// The ink: a plain view that asks for its own surface, drawing a solid red block.
class InkView : UXView
    {
    i32 painted;
    void init(void) { super.init(); painted = (i32)0; }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        painted = painted + (i32)1;
        g.clearRect(self.bounds()); // the client's ink starts every frame like this
        g.fillRectRGB(UXGeom.make((i16)0, (i16)0, (i16)120, (i16)48), (i32)230, (i32)20, (i32)20);
        }
    }

i32 isRed(i32 c) { return ((c >> (i32)16) & (i32)255) > (i32)200 && ((c >> (i32)8) & (i32)255) < (i32)60 ? (i32)1 : (i32)0; }

class Controller : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    UXWindow* win;
    MapView* map;
    InkView* ink;

    void checkLive(void)
        {
        ck(ink.kind() == UXKindSurface, "the ink view reports UXKindSurface");
        ck(map.makeGL(), "the map made its offscreen surface");
        map.presentGL();
        win.displayAll();

        // (100,100) is on the map and under the ink; (40,40) is on the map only; (5,5) is neither.
        ux_ak_gl_grab_window((pointer)map, (u8*)"/tmp/surface_over_gl.png");
        i32 bg = ux_ak_gl_grab_pixel((i32)5, (i32)5);
        i32 onMap = ux_ak_gl_grab_pixel((i32)40, (i32)40);
        i32 underInk = ux_ak_gl_grab_pixel((i32)100, (i32)100);
        ck(onMap != bg, "the map is in the window picture");
        ck(isRed(underInk) != (i32)0, "the ink is drawn OVER the map");
        // (230,140) is inside the ink view's bounds, which it CLEARED, but outside what it inked.
        ck(ux_ak_gl_grab_pixel((i32)230, (i32)140) == onMap, "the ink's clearRect leaves the map beneath it");

        ink.setHidden(true);
        map.presentGL();
        win.displayAll();
        ux_ak_gl_grab_window((pointer)map, (u8*)"/tmp/surface_over_gl_hidden.png");
        i32 afterHide = ux_ak_gl_grab_pixel((i32)100, (i32)100);
        ck(isRed(afterHide) == (i32)0, "hiding the ink shows the map at that point again");
        ck(afterHide == ux_ak_gl_grab_pixel((i32)40, (i32)40), "...the same map as next to it");
        ink.setHidden(false);
        Stdio.printf("  bg=%06lx map=%06lx ink=%06lx hidden=%06lx\n", bg, onMap, underInk, afterHide);
        }

    void checkHeadless(void)
        {
        ck(ink.kind() == UXKindSurface, "the ink view still reports UXKindSurface");
        win.displayAll();
        i32 first = ink.painted;
        ck(first > (i32)0, "the view painted inline through drawRect");
        win.displayAll();
        ck(ink.painted > first, "and paints again -- drawRect is the renderer here");
        Stdio.printf("  ink painted=%d (inline)\n", ink.painted);
        }

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        bool headless = getenv((u8*)"UX_GL_HEADLESS") != (u8*)0;

        UXView* canvas = new UXView();
        win = new UXWindow();
        win.open((u8*)"UXKit 2-D over GL", UXGeom.make((i16)160, (i16)160, (i16)340, (i16)260), canvas);

        map = new MapView();
        canvas.addSubview(map, UXGeom.make((i16)20, (i16)20, (i16)300, (i16)180));
        ink = new InkView();
        ink.setOwnSurface(true); // BEFORE it is attached: the choice becomes the view's kind
        canvas.addSubview(ink, UXGeom.make((i16)60, (i16)60, (i16)200, (i16)100)); // bigger than its ink

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
            Stdio.printf("PASS: AppKit 2-D over GL (headless) -- the view paints inline\n");
        else
            Stdio.printf("PASS: AppKit 2-D over GL -- the map is in the window and the ink is drawn over it, one surface\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
