// test_ios_gl.xc — GL on iOS (the ios-gl gate): OpenGL ES 3 through the neutral seam,
// rendered offscreen and painted in the window's own 2-D pass.  The app owns the renderer (it finds
// its entry points with glProc and calls them); the driver owns the surface, its viewport and its
// present.  Checked: the kind; a context made, idempotent, opaque; entry points found and an unknown
// name 0; the viewport the drawable's PIXEL size (the view's points times the density); a frame
// cleared to a colour only this run uses, read back from the drawable AND from the window after the
// paint; a 2-D view after the GL view in the tree painted OVER it; destroy then remake.
#import <Stdio.xc>
#import "UXImage.xc"
#import "UXIosDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"

extern void ux_ios_set_entry(pointer fn);
extern void ux_ios_shell_run(void);
extern void ux_ios_quit(i32 rc);
extern void ux_ios_test_watchdog(i32 ms, i32 rc);
extern void ux_ios_render(i32 handle);
extern i32 ux_ios_pixel(i32 x, i32 y);
extern i32 ux_ios_test_gl_size(pointer view, i32* w, i32* h);
extern void ux_ios_test_call_later(pointer fn, i32 ms);
extern void ux_ios_test_gl_max(i32 max);

typedef u8* GetStrFn(u32 which);
typedef void ClearColorFn(float r, float g, float b, float a);
typedef void ClearFn(u32 mask);
typedef void FinishFn(void);
typedef u32 GetErrFn(void);
typedef void GetIntFn(u32 which, i32* out);
typedef void ReadPixelsFn(i32 x, i32 y, i32 w, i32 h, u32 fmt, u32 type, pointer px);
typedef void EnableFn(u32 cap);
typedef void ScissorFn(i32 x, i32 y, i32 w, i32 h);

i32 gFails;
void ck(bool ok, u8* what)
    {
    Stdio.printf(ok ? "  ok   %s\n" : "  FAIL %s\n", what);
    if (!ok)
        {
        gFails = gFails + (i32)1;
        }
    }
bool near(i32 px, i32 r, i32 g, i32 b)
    {
    i32 pr = (px >> (i32)16) & (i32)255;
    i32 pg = (px >> (i32)8) & (i32)255;
    i32 pb = px & (i32)255;
    return pr > r - (i32)12 && pr < r + (i32)12 && pg > g - (i32)12 && pg < g + (i32)12 && pb > b - (i32)12 && pb < b + (i32)12;
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
        g.fillRectRGB(self.bounds(), (i32)0, (i32)0, (i32)0);
        }
    }
class OverView : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)230, (i32)20, (i32)20);
        }
    }

void finish(void)
    {
    ux_ios_quit(gFails == (i32)0 ? (i32)0 : (i32)1);
    }

void testBody(void)
    {
    gFails = (i32)0;
    ux_ios_test_watchdog((i32)30000, (i32)2);
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    gDriver.boot(&sw, &sh);
    UXView* canvas = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"gl", UXGeom.make((i16)0, (i16)0, (i16)360, (i16)300), canvas);
    UXApplication* app = new UXApplication();
    app.running = true;
    gApp = app;
    app.addWindow(win);
    MapView* map = new MapView();
    canvas.addSubview(map, UXGeom.make((i16)0, (i16)0, (i16)360, (i16)300));
    OverView* over = new OverView();
    canvas.addSubview(over, UXGeom.make((i16)100, (i16)100, (i16)50, (i16)50)); // AFTER the map: over it
    win.displayAll();

    ck(map.glKind() == (i32)UX_GL_GLES3, "the backend offers OpenGL ES 3");
    i32 paintedBefore = map.painted;
    bool made = map.makeGL();
    ck(made && map.glContext() != (pointer)0, "a context was made, and the view owns it");
    pointer tok = map.glContext();
    ck(map.makeGL() && map.glContext() == tok, "makeGL is idempotent");
    if (!made)
        {
        Stdio.printf("FAIL: %d\n", gFails);
        ux_ios_quit((i32)1);
        return;
        }
    GetStrFn* ver = (GetStrFn*)gDriver.glProc((u8*)"glGetString");
    ck(ver != (GetStrFn*)0, "glProc finds glGetString");
    if (ver != (GetStrFn*)0)
        {
        Stdio.printf("  (version: %s)\n", ver((u32)$1F02));
        }
    ck(gDriver.glProc((u8*)"glNoSuchEntryPointXyz") == (pointer)0, "an unknown name resolves to zero");
    GetIntFn* gi = (GetIntFn*)gDriver.glProc((u8*)"glGetIntegerv");
    ClearColorFn* cc = (ClearColorFn*)gDriver.glProc((u8*)"glClearColor");
    ClearFn* cl = (ClearFn*)gDriver.glProc((u8*)"glClear");
    FinishFn* fin = (FinishFn*)gDriver.glProc((u8*)"glFinish");
    GetErrFn* ge = (GetErrFn*)gDriver.glProc((u8*)"glGetError");
    ReadPixelsFn* rp = (ReadPixelsFn*)gDriver.glProc((u8*)"glReadPixels");

    i32 dw = (i32)0;
    i32 dh = (i32)0;
    ux_ios_test_gl_size((pointer)map, &dw, &dh);
    i32 vp[4];
    vp[0] = (i32)-1;
    vp[1] = (i32)-1;
    vp[2] = (i32)-1;
    vp[3] = (i32)-1;
    gi((u32)$0BA2, &vp[0]); // GL_VIEWPORT
    Stdio.printf("  (drawable %dx%d, viewport %d %d %d %d)\n", dw, dh, vp[0], vp[1], vp[2], vp[3]);
    ck(vp[2] == dw && vp[3] == dh && dw >= (i32)360 && dw * (i32)300 - dh * (i32)360 < (i32)400 && dh * (i32)360 - dw * (i32)300 < (i32)400,
       "the viewport is the drawable's pixel size, the view's shape");

    cc(0.25, 0.5, 0.75, 1.0);
    cl((u32)$4000); // GL_COLOR_BUFFER_BIT
    fin();
    u8 px[4];
    rp((i32)20, (i32)20, (i32)1, (i32)1, (u32)$1908, (u32)$1401, &px[0]); // RGBA, UNSIGNED_BYTE
    ck((i32)px[0] > (i32)55 && (i32)px[0] < (i32)75 && (i32)px[1] > (i32)118 && (i32)px[1] < (i32)138,
       "the drawn colour reached the drawable");
    ck(ge() == (u32)0, "no GL error over the frame");
    map.presentGL();
    ck(ge() == (u32)0, "no GL error over the present");

    // the drawable's size and the frame alone, through the neutral calls
    i32 nw = (i32)0;
    i32 nh = (i32)0;
    ck(map.drawableSize(&nw, &nh) && nw == dw && nh == dh, "drawableSize is the drawable's pixels");
    UXImage* frame = map.snapshot();
    ck(frame != (UXImage*)0 && frame.w == dw && frame.h == dh, "the GL view's snapshot is its frame, at the drawable's size");
    u32 mid = frame != (UXImage*)0 ? frame.px[(dh / (i32)2) * dw + dw / (i32)2] : (u32)0;
    ck(near((i32)(mid & (u32)$FFFFFF), (i32)64, (i32)128, (i32)191), "...in the colour the frame was cleared to");

    win.displayAll();
    ux_ios_render(win.handle);
    i32 at = ux_ios_pixel((i32)20, (i32)20);
    Stdio.printf("  (window pixel %06x)\n", at);
    ck(near(at, (i32)64, (i32)128, (i32)191), "the frame is in the WINDOW's paint");
    Stdio.printf("  (drawRect ran %d time(s) before makeGL, %d after)\n", paintedBefore, map.painted - paintedBefore);
    ck(map.painted == paintedBefore, "...and drawRect never paints the GL view once it owns a context");
    ck(near(ux_ios_pixel((i32)120, (i32)120), (i32)230, (i32)20, (i32)20), "a 2-D view after the map is painted OVER it");

    map.destroyGL();
    ck(map.glContext() == (pointer)0, "destroyGL releases the context");
    ck(map.makeGL(), "...and it can be made again");
    cc(0.125, 0.75, 0.25, 1.0);
    cl((u32)$4000);
    map.presentGL();
    win.displayAll();
    ux_ios_render(win.handle);
    ck(near(ux_ios_pixel((i32)300, (i32)250), (i32)32, (i32)191, (i32)64), "the remade context's frame reaches the window");
    // ORIENTATION: GL's rows run bottom-up.  Clear only the drawable's BOTTOM half blue; the window
    // must show blue at the bottom of the view and keep the green at its top.
    EnableFn* en = (EnableFn*)gDriver.glProc((u8*)"glEnable");
    EnableFn* dis = (EnableFn*)gDriver.glProc((u8*)"glDisable");
    ScissorFn* sc = (ScissorFn*)gDriver.glProc((u8*)"glScissor");
    en((u32)$0C11); // GL_SCISSOR_TEST
    sc((i32)0, (i32)0, dw, dh / (i32)2);
    cc(0.0, 0.0, 1.0, 1.0);
    cl((u32)$4000);
    dis((u32)$0C11);
    map.presentGL();
    win.displayAll();
    ux_ios_render(win.handle);
    ck(near(ux_ios_pixel((i32)300, (i32)280), (i32)0, (i32)0, (i32)255) && near(ux_ios_pixel((i32)300, (i32)20), (i32)32, (i32)191, (i32)64),
       "the frame is the right way up: GL's bottom rows at the bottom of the view");

    // THE CLAMP: the drawable never exceeds what the GPU can hold.  The real limit is far above
    // this view, so the test lowers it to 64: the drawable must become 64 wide with the view's
    // aspect, the viewport must follow, and the frame must still cover the view (stretched).
    ux_ios_test_gl_max((i32)64);
    gDriver.resizeGL((pointer)map, (i32)360, (i32)300);
    ux_ios_test_gl_size((pointer)map, &dw, &dh);
    gi((u32)$0BA2, &vp[0]);
    Stdio.printf("  (clamped drawable %dx%d, viewport %dx%d)\n", dw, dh, vp[2], vp[3]);
    ck(dw == (i32)64 && dh == (i32)53 && vp[2] == (i32)64 && vp[3] == (i32)53, "the drawable is clamped to 64 with the view's aspect, and the viewport follows");
    cc(1.0, 0.5, 0.0, 1.0);
    cl((u32)$4000);
    map.presentGL();
    win.displayAll();
    ux_ios_render(win.handle);
    ck(near(ux_ios_pixel((i32)355, (i32)295), (i32)255, (i32)128, (i32)0), "...and its frame is stretched over the whole view, to the far corner");
    ux_ios_test_gl_max((i32)0);

    Stdio.printf(gFails == (i32)0 ? "PASS: GL on iOS -- OpenGL ES 3 offscreen, its frame in the window's paint, 2-D over it\n" : "FAIL: %d\n", gFails);
    ux_ios_test_call_later((pointer)&finish, (i32)2500); // up a moment, for a screenshot
    }

void main(void)
    {
    gDriver = new UXIosDriver();
    ux_ios_set_entry((pointer)&testBody);
    ux_ios_shell_run();
    }
