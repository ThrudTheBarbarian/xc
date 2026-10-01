// test_win32_gl.xc — the Win32 GL surface, driven through the neutral seam.
//
// The seam's rule is that the DRIVER owns the surface: it makes the drawable when the
// tree is realized, binds a context in makeGL, sets the viewport from the client rect,
// and swaps in presentGL.  The app owns the RENDERER: it asks the backend where an
// entry point is (glProc) and calls it itself.  This gate drives that from the app side
// and checks the parts a renderer depends on and nothing else does:
//
//   - the backend answers a GL kind, and offers the entry points a renderer loads;
//   - makeGL returns a context and is idempotent; the token is opaque and not the raw
//     context a second caller could free;
//   - the viewport is the SURFACE's size, set by the driver and not by the app;
//   - a frame drawn through the entry points lands on the drawable (read back), and the
//     swap is clean;
//   - a GL view never falls back to drawRect once it has a context, and destroy/recreate
//     after close is safe.
//
// HONEST LIMIT: this machine's Wine offers a 2.1 compatibility context ("2.1 Metal"),
// so what is proven here is the SURFACE PLUMBING — pixel format, context, viewport,
// swap, readback — and NOT a core-profile 3.3 shader draw, which no Wine on this box
// can give.  The version string is printed so the claim is bounded by what it says.
//
//   Build+run:  sh run_win32_gl.sh   (xcc -A win64 -> .exe, run under Wine; needs wine)
#import <Stdio.xc>
#import "UXWin32Driver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

typedef u8* GetStrFn(u32 which);
typedef void Void4Fn(i32 a, i32 b, i32 c, i32 d);
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

// An app's GL view: a software fallback for the backends that cannot give it a context,
// and nothing else.  If this ever runs on Win32 the seam's one rule is broken.
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

// A 2-D view laid over the map: a solid red block.  Before the one-surface model nothing drawn by the
// toolkit could land on a Win32 GL view -- the GL was a child window, and Windows clips the parent's
// paint around its children.
class OverView : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)230, (i32)20, (i32)20);
        }
    }

    class Delegate : Object<UXApplicationDelegate>
    {
    UXWin32Driver* drv;
    void setDriver(UXWin32Driver* d)
        {
        drv = d;
        }

    // GL constants: the ones the frame below needs, named locally so the gate does not
    // depend on a header it is not testing.
    i32 applicationDidStart(UXApplication* app)
        {
        UXView* canvas = new UXView();
        UXWindow* win = new UXWindow();
        win.open((u8*)"UXKit GL surface", UXGeom.make((i16)40, (i16)40, (i16)640, (i16)400), canvas);
        app.addWindow(win);

        MapView* map = new MapView();
        canvas.addSubview(map, UXGeom.make((i16)0, (i16)0, (i16)640, (i16)400));
        OverView* over = new OverView();
        canvas.addSubview(over, UXGeom.make((i16)100, (i16)100, (i16)50, (i16)50)); // AFTER the map: over it
        win.displayAll();
        // With no context yet the GL view IS painted, through its software fallback: that is
        // the seam's promise to a backend -- or a moment -- that cannot give it a context.
        // The number is captured here so the paint after makeGL can be compared against it.
        i32 paintedNoCtx = map.painted;
        Stdio.printf("painted before makeGL=%d\n", paintedNoCtx);

        // The kind is the backend's answer and it comes before anything is made.
        Stdio.printf("glKind=%d\n", map.glKind());
        ck(map.glKind() == (i32)UX_GL_GL33, "the backend offers a GL 3.3 profile");

        bool made = map.makeGL();
        ck(made, "a context was made");
        ck(map.glContext() != (pointer)0, "the view owns a context");
        if (!made)
            {
            Stdio.printf("FAIL: %d\n", gFails);
            app.stop();
            return (i32)0;
            }

        // Where the entry points are is the backend's business; the renderer only asks.
        GetStrFn* ver = (GetStrFn*)drv.glProc((u8*)"glGetString");
        ck(ver != (GetStrFn*)0, "glProc finds glGetString");
        if (ver != (GetStrFn*)0)
            {
            u8* v = ver((u32)0x1F02); // GL_VERSION
            Stdio.printf("version %s\n", v);
            }
        ck(drv.glProc((u8*)"glNoSuchEntryPointXyz") == (pointer)0, "an unknown name resolves to zero");

        Void4Fn* vp = (Void4Fn*)drv.glProc((u8*)"glViewport");
        GetIntFn* gi = (GetIntFn*)drv.glProc((u8*)"glGetIntegerv");
        ClearColorFn* cc = (ClearColorFn*)drv.glProc((u8*)"glClearColor");
        ClearFn* cl = (ClearFn*)drv.glProc((u8*)"glClear");
        FinishFn* fin = (FinishFn*)drv.glProc((u8*)"glFinish");
        GetErrFn* ge = (GetErrFn*)drv.glProc((u8*)"glGetError");
        ReadPixelsFn* rp = (ReadPixelsFn*)drv.glProc((u8*)"glReadPixels");
        ck(vp != (Void4Fn*)0 && gi != (GetIntFn*)0 && cc != (ClearColorFn*)0, "the drawing calls resolve");
        ck(cl != (ClearFn*)0 && fin != (FinishFn*)0 && ge != (GetErrFn*)0 && rp != (ReadPixelsFn*)0, "...and the frame calls resolve");

        // The viewport is set by the DRIVER, from the surface's size, not by the app.
        i32 viewport[4];
        viewport[0] = (i32)-1; viewport[1] = (i32)-1; viewport[2] = (i32)-1; viewport[3] = (i32)-1;
        gi((u32)0x0BA2, &viewport[0]); // GL_VIEWPORT
        Stdio.printf("viewport %d %d %d %d\n", viewport[0], viewport[1], viewport[2], viewport[3]);
        ck(viewport[2] == (i32)640 && viewport[3] == (i32)400, "the viewport is the surface's size");

        // A frame: clear to a colour only this run uses, read one pixel back, then swap.
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
        ck(ge() == (u32)0, "no GL error over the present");

        // ONE SURFACE: the frame was rendered offscreen and is blitted in the window's own paint, so
        // after a paint the WINDOW's pixel is the map's -- the thing a visible GL child window made
        // impossible for anything else drawn there.
        ck(gW32GlOff[(i32)0] != (i32)0, "the GL renders offscreen (framebuffer objects are there)");
        win.displayAll();
        pointer hw = gW32Hwnds[win.handle];
        UpdateWindow(hw);
        pointer wdc = GetDC(hw);
        u32 c = GetPixel(wdc, (i32)20, (i32)20);
        ReleaseDC(hw, wdc);
        i32 wr = (i32)(c & (u32)255);
        i32 wg = (i32)((c >> (u32)8) & (u32)255);
        i32 wb = (i32)((c >> (u32)16) & (u32)255);
        Stdio.printf("window pixel %d %d %d\n", wr, wg, wb);
        ck(wr > (i32)50 && wr < (i32)80 && wg > (i32)115 && wg < (i32)140 && wb > (i32)175 && wb < (i32)205,
           "the frame is in the WINDOW's paint, not on a plane of its own");
        pointer wdc2 = GetDC(hw);
        u32 c2 = GetPixel(wdc2, (i32)120, (i32)120);
        ReleaseDC(hw, wdc2);
        Stdio.printf("over-the-map pixel %d %d %d\n", (i32)(c2 & (u32)255), (i32)((c2 >> (u32)8) & (u32)255), (i32)((c2 >> (u32)16) & (u32)255));
        ck((i32)(c2 & (u32)255) > (i32)200 && (i32)((c2 >> (u32)8) & (u32)255) < (i32)60, "a 2-D view after the map is painted OVER it");

        // The drawable is CLAMPED to what the GPU can hold, keeping the aspect, and the paint stretches
        // the frame back over the view.  The real limit is far above 640, so the test lowers it to 64:
        // 640x400 must become 64x40, the viewport must follow, and the window must show the frame all
        // the way to the view's far corner (stretched, not cropped).
        gW32GlTestMax = (i32)64;
        map.presentGL(); // notices the drawable is over the limit and remakes it for the next frame
        Stdio.printf("clamped drawable %dx%d\n", gW32GlPW[(i32)0], gW32GlPH[(i32)0]);
        ck(gW32GlPW[(i32)0] == (i32)64 && gW32GlPH[(i32)0] == (i32)40, "the drawable is clamped to 64 with the view's aspect");
        gi((u32)0x0BA2, &viewport[0]); // GL_VIEWPORT
        ck(viewport[2] == (i32)64 && viewport[3] == (i32)40, "and the viewport follows the drawable");
        cc(0.125, 0.75, 0.25, 1.0);
        cl((u32)0x00004000);
        map.presentGL();
        win.displayAll();
        UpdateWindow(hw);
        pointer wdc3 = GetDC(hw);
        u32 cFar = GetPixel(wdc3, (i32)636, (i32)396);
        u32 cNear = GetPixel(wdc3, (i32)3, (i32)3);
        ReleaseDC(hw, wdc3);
        Stdio.printf("clamped frame: near %06x far %06x (COLORREF)\n", cNear, cFar);
        bool farG = ((cFar >> (u32)8) & (u32)255) > (u32)160 && (cFar & (u32)255) < (u32)60;
        bool nearG = ((cNear >> (u32)8) & (u32)255) > (u32)160 && (cNear & (u32)255) < (u32)60;
        ck(farG && nearG, "the clamped frame still fills the whole view");
        gW32GlTestMax = (i32)0;
        map.presentGL(); // back to the full size for the rest

        // The token is opaque and makeGL is idempotent: a second call is the same context.
        pointer tok = map.glContext();
        ck(map.makeGL() && map.glContext() == tok, "makeGL is idempotent");

        // The seam's one rule: a GL view with a context is NOT painted by drawRect.  The
        // first displayAll did paint it (there was no context then, and the check that it
        // did is what makes this one mean something); a repaint now must not.
        ck(paintedNoCtx > (i32)0, "without a context the GL view is painted (the fallback)");
        i32 paintedWithCtx = map.painted;
        win.displayAll();
        ck(map.painted == paintedWithCtx, "a paint with a context does not fall back to drawRect");

        // Destroy and recreate: the close path a GL client is most likely to crash on.
        map.destroyGL();
        ck(map.glContext() == (pointer)0, "the token is released");
        map.destroyGL(); // idempotent
        ck(map.makeGL() && map.glContext() != (pointer)0, "a context can be made again after destroy");
        map.destroyGL();

        if (gFails == 0)
            {
            Stdio.printf("PASS: win32 GL — surface, context, driver-set viewport, a drawn pixel and a clean close\n");
            }
        else
            {
            Stdio.printf("FAIL: %d\n", gFails);
            }
        app.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXWin32Driver* d = new UXWin32Driver();
    gDriver = d;
    Delegate* del = new Delegate();
    del.setDriver(d);
    UXApplication* app = new UXApplication();
    app.setDelegate(del);
    i32 rc = app.run();
    Stdio.printf("stopped rc=%d\n", rc);
    }
