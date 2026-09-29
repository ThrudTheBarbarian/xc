// test_web_gl.xc — the web (WebGL2) GL surface, driven through the neutral seam.
//
// Sibling of test_win32_gl.xc and test_gtk_gl.xc.  What this backend can and cannot
// prove is different and the difference is stated here rather than papered over:
//
//   - the SURFACE is the host's, so this gate checks the driver made one at
//     realization, made the context current, set the VIEWPORT from the view's frame,
//     and presented -- the rig records all four and the gate reads them back.  There
//     is no GPU under Node, so unlike the GTK gate there is no pixel to read.
//   - the ENTRY POINTS are host imports the renderer declares, and glProc answers 0
//     BY DESIGN: on wasm a pointer to an import compiles but traps when called
//     ("null function or function signature mismatch"), so handing one out through
//     glProc could never be called.  The gate asserts the 0 so the contract is
//     pinned rather than accidental, and an entry point is exercised as an IMPORT.
//
//   Build+run:  sh run_web_gl.sh
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

// The rig's introspection surface (ux_web_node.js), not part of the driver.
extern i32 ux_test_gl_state(i32 h, i32* out4); // {created, current, vpW, vpH}
extern i32 ux_test_gl_presents(i32 h);

// A GL entry point as it is delivered on the web: a HOST IMPORT the renderer
// declares.  This one is the rig's, and it exists to prove the delivery path.
extern i32 ux_host_add(i32 a, i32 b);

i32 gFails = 0;
void ck(bool ok, u8* what)
    {
    if (!ok)
        {
        Stdio.printf("  no: %s\n", what);
        gFails = gFails + 1;
        }
    }

class MapView : UXGLView
    {
    i32 painted;
    void init(void)
        {
        super.init();
        painted = (i32)0;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        painted = painted + (i32)1;
        }
    }

void main(void)
    {
    UXWebDriver* wd = new UXWebDriver();
    gDriver = wd; // the ONE web-aware line
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("boot failed\n");
        return;
        }

    UXWindow* win = new UXWindow();
    UXView* canvas = new UXView();
    MapView* map = new MapView();
    win.open((u8*)"UXKit GL surface", UXGeom.make((i16)0, (i16)0, (i16)640, (i16)400), canvas);
    canvas.addSubview(map, UXGeom.make((i16)0, (i16)0, (i16)640, (i16)400));
    win.displayAll(); // realizeTree: the host canvas
    wd.webPresentAll();

    i32 paintedNoCtx = map.painted;

    Stdio.printf("glKind=%d\n", map.glKind());
    ck(map.glKind() == (i32)UX_GL_WEBGL2, "the backend answers WebGL2");

    // glProc is 0 on this backend BY DESIGN (see the file header); pin it.
    ck(wd.glProc((u8*)"glClearColor") == (pointer)0, "glProc answers 0 (the web delivers entry points as imports)");

    bool made = map.makeGL();
    ck(made, "a context was made");
    ck(map.glContext() != (pointer)0, "the view owns a context");
    if (!made)
        {
        Stdio.printf("FAIL: %d\n", gFails);
        win.close();
        return;
        }

    i32 st[4];
    st[0] = (i32)0; st[1] = (i32)0; st[2] = (i32)0; st[3] = (i32)0;
    ck(ux_test_gl_state(win.handle, &st[0]) == (i32)1, "the host has a GL record for the window");
    Stdio.printf("gl created=%d current=%d viewport %d %d\n", st[0], st[1], st[2], st[3]);
    ck(st[0] == (i32)1, "the surface was made at realization");
    ck(st[1] == (i32)1, "the context is current after makeGL");
    ck(st[2] == (i32)640 && st[3] == (i32)400, "the driver set the viewport from the view's frame");

    map.presentGL();
    ck(ux_test_gl_presents(win.handle) == (i32)1, "presentGL reached the host");

    // The entry-point DELIVERY on this backend: an import the renderer declares,
    // called directly.  This is what replaces glProc here.
    ck(ux_host_add((i32)20, (i32)22) == (i32)42, "a GL entry point is callable as a host import");

    pointer tok = map.glContext();
    ck(map.makeGL() && map.glContext() == tok, "makeGL is idempotent");

    ck(paintedNoCtx > (i32)0, "without a context the GL view is painted (the fallback)");
    i32 paintedWithCtx = map.painted;
    win.displayAll();
    ck(map.painted == paintedWithCtx, "a paint with a context does not fall back to drawRect");

    map.destroyGL();
    ck(map.glContext() == (pointer)0, "the token is released");
    map.destroyGL(); // idempotent
    ck(map.makeGL() && map.glContext() != (pointer)0, "a context can be made again after destroy");
    map.destroyGL();

    win.close();
    ck(gDriver.liveNativeCount() == (i32)0, "the window closed and left no native object");

    if (gFails == 0)
        {
        Stdio.printf("PASS: web GL — surface, context, driver-set viewport, one present and a clean close\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
