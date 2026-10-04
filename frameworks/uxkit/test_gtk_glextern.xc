// test_gtk_glextern.xc — a renderer's GL calls as plain externs on GTK (the gtk-glextern check).  The
// client's renderer declares glClear, glDrawArrays ... as ordinary C functions and links them; on
// macOS that is -framework OpenGL.  This checks the same declarations work against GTK's context
// when the build links the platform's GL library (Linux: -lGL, GLVND's), including a call newer
// than GL 1.1 (glGenFramebuffers): the source does not change, only the link line.
#import <Stdio.xc>
#import "UXGtkDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
void ux_gtk_wait_allocated(i32 handle);
void glClearColor(float r, float g, float b, float a);
void glClear(u32 mask);
void glFinish(void);
u32 glGetError(void);
void glReadPixels(i32 x, i32 y, i32 w, i32 h, u32 format, u32 type, pointer data);
void glGenFramebuffers(i32 n, u32* ids);
void glDeleteFramebuffers(i32 n, u32* ids);

i32 gFails;
void ck(bool ok, u8* what)
    {
    Stdio.printf("  %s %s\n", ok ? (u8*)"ok  " : (u8*)"FAIL", what);
    if (!ok)
        {
        gFails = gFails + (i32)1;
        }
    }
void main(void)
    {
    gFails = (i32)0;
    gDriver = new UXGtkDriver();
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    if (!gDriver.boot(&sw, &sh))
        {
        Stdio.printf("SKIP: no display\n");
        return;
        }
    UXWindow* win = new UXWindow();
    UXView* canvas = new UXView();
    UXGLView* map = new UXGLView();
    win.open((u8*)"glextern", UXGeom.make((i16)60, (i16)60, (i16)320, (i16)200), canvas);
    canvas.addSubview(map, UXGeom.make((i16)0, (i16)0, (i16)320, (i16)200));
    win.displayAll();
    ux_gtk_wait_allocated(win.handle);
    ck(map.makeGL(), "a context was made");
    glClearColor(0.25, 0.5, 0.75, 1.0);
    glClear((u32)$4000);
    glFinish();
    u8 px[4];
    px[0] = (u8)0;
    px[1] = (u8)0;
    px[2] = (u8)0;
    glReadPixels((i32)10, (i32)10, (i32)1, (i32)1, (u32)$1908, (u32)$1401, (pointer)&px[0]);
    Stdio.printf("  (pixel %d %d %d)\n", (i32)px[0], (i32)px[1], (i32)px[2]);
    ck((i32)px[0] > (i32)50 && (i32)px[0] < (i32)80 && (i32)px[1] > (i32)115 && (i32)px[1] < (i32)140, "plain glClear / glReadPixels act on GTK's context");
    u32 fb = (u32)0;
    glGenFramebuffers((i32)1, &fb);
    ck(fb != (u32)0 && glGetError() == (u32)0, "...and so does a call newer than GL 1.1 (glGenFramebuffers)");
    glDeleteFramebuffers((i32)1, &fb);
    map.presentGL();
    Stdio.printf(gFails == (i32)0 ? "PASS: a renderer's plain GL externs work on GTK, the link line naming the GL library\n" : "FAIL: %d\n", gFails);
    }
