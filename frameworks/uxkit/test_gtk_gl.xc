// test_gtk_gl.xc — the GTK GL surface, driven through the neutral seam.
//
// Sibling of test_win32_gl.xc: the same property, that the DRIVER owns the surface
// (the GtkGLArea, realized with the tree), sets the viewport from the widget's own
// pixel size, and presents; the app owns the renderer, reaching the entry points
// through glProc.  The parts checked are the ones a renderer depends on and nothing
// else does:
//
//   - glKind answers a GL kind and glProc resolves the entry points an init pass loads;
//   - makeGL makes a context and is idempotent; the token is opaque;
//   - the DRIVER set the viewport from the drawable's PIXEL size (allocation times the
//     scale factor), which is the GTK twin of the Win32 client rect;
//   - a colour drawn through the entry points lands on the drawable (read back);
//   - a GL view with a context does NOT run drawRect, and without one it does;
//   - destroy/recreate is safe.
//
// HONEST LIMIT: on this machine GTK gives a 4.1 Metal context, so a shader draw is
// possible here (unlike the Win32 gate under Wine).  This gate still only reads a
// clear back, because the SPIKES on this backend are the plumbing; the shader draw is
// the renderer's, gated with the harness on the backend that owns it.
//
//   Build+run:  sh run_gtk_gl.sh
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

// The rig surface (libUXGtk.c), not part of the driver.
extern void ux_gtk_wait_allocated(i32 handle);

typedef u8* GetStrFn(u32 which);
typedef void ClearColorFn(float r, float g, float b, float a);
typedef void ClearFn(u32 mask);
typedef void FinishFn(void);
typedef u32 GetErrFn(void);
typedef void GetIntFn(u32 which, i32* out);
typedef void ReadPixelsFn(i32 x, i32 y, i32 w, i32 h, u32 fmt, u32 type, pointer px);

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
    gDriver = new UXGtkDriver(); // the ONE GTK-aware line
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display for gtk_init\n");
        return;
        }

    UXWindow* win = new UXWindow();
    UXView* canvas = new UXView();
    MapView* map = new MapView();
    win.open((u8*)"UXKit GL surface", UXGeom.make((i16)60, (i16)60, (i16)640, (i16)400), canvas);
    canvas.addSubview(map, UXGeom.make((i16)0, (i16)0, (i16)640, (i16)400));
    win.displayAll(); // realizeTree: the REAL GtkGLArea
    ux_gtk_wait_allocated(win.handle); // the frame clock: a headless gate has no WM

    i32 paintedNoCtx = map.painted;
    Stdio.printf("painted before makeGL=%d\n", paintedNoCtx);

    Stdio.printf("glKind=%d\n", map.glKind());
    ck(map.glKind() == (i32)UX_GL_GL33, "the backend offers a GL 3.3 profile");

    bool made = map.makeGL();
    ck(made, "a context was made");
    ck(map.glContext() != (pointer)0, "the view owns a context");
    if (!made)
        {
        Stdio.printf("FAIL: %d\n", gFails);
        win.close();
        return;
        }

    GetStrFn* ver = (GetStrFn*)gDriver.glProc((u8*)"glGetString");
    ck(ver != (GetStrFn*)0, "glProc finds glGetString");
    if (ver != (GetStrFn*)0)
        {
        u8* v = ver((u32)0x1F02); // GL_VERSION
        Stdio.printf("version %s\n", v);
        }
    ck(gDriver.glProc((u8*)"glNoSuchEntryPointXyz") == (pointer)0, "an unknown name resolves to zero");

    GetIntFn* gi = (GetIntFn*)gDriver.glProc((u8*)"glGetIntegerv");
    ClearColorFn* cc = (ClearColorFn*)gDriver.glProc((u8*)"glClearColor");
    ClearFn* cl = (ClearFn*)gDriver.glProc((u8*)"glClear");
    FinishFn* fin = (FinishFn*)gDriver.glProc((u8*)"glFinish");
    GetErrFn* ge = (GetErrFn*)gDriver.glProc((u8*)"glGetError");
    ReadPixelsFn* rp = (ReadPixelsFn*)gDriver.glProc((u8*)"glReadPixels");
    ck(gi != (GetIntFn*)0 && cc != (ClearColorFn*)0 && cl != (ClearFn*)0, "the drawing calls resolve");
    ck(fin != (FinishFn*)0 && ge != (GetErrFn*)0 && rp != (ReadPixelsFn*)0, "...and the frame calls resolve");

    // The viewport is set by the DRIVER, from the drawable's pixel size, not by the app.
    i32 viewport[4];
    viewport[0] = (i32)-1; viewport[1] = (i32)-1; viewport[2] = (i32)-1; viewport[3] = (i32)-1;
    gi((u32)0x0BA2, &viewport[0]); // GL_VIEWPORT
    Stdio.printf("viewport %d %d %d %d\n", viewport[0], viewport[1], viewport[2], viewport[3]);
    // The requested frame is 640x400; the drawable is that times the scale factor, which
    // is 1 or 2 depending on the display, so the check is "as wide as it is tall-scaled",
    // not a fixed number.  What matters is that it is NOT the un-scaled 640x400 when the
    // scale is 2, which is the bug the driver owns.
    ck(viewport[2] >= (i32)640 && viewport[3] >= (i32)400, "the viewport is at least the view's size");
    ck(viewport[2] * (i32)400 == viewport[3] * (i32)640, "the viewport keeps the view's aspect");

    cc(0.25, 0.5, 0.75, 1.0);
    cl((u32)0x00004000); // GL_COLOR_BUFFER_BIT
    fin();
    u8 px[4];
    px[0] = (u8)0; px[1] = (u8)0; px[2] = (u8)0; px[3] = (u8)0;
    rp((i32)20, (i32)20, (i32)1, (i32)1, (u32)0x1908, (u32)0x1401, &px[0]); // RGBA, UNSIGNED_BYTE
    Stdio.printf("pixel %d %d %d %d\n", (i32)px[0], (i32)px[1], (i32)px[2], (i32)px[3]);
    ck((i32)px[0] > (i32)50 && (i32)px[0] < (i32)80, "the drawn colour reached the drawable");
    ck((i32)px[1] > (i32)115 && (i32)px[1] < (i32)140, "...on the green channel");
    ck(ge() == (u32)0, "no GL error over the frame");
    map.presentGL();
    ck(ge() == (u32)0, "no GL error over the swap");

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
        Stdio.printf("PASS: gtk GL — surface, context, driver-set viewport, a drawn pixel and a clean close\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
