// test_gl_renderer.xc — a GL 3.2-core renderer through UXGL.xc, one source on every backend (the
// gl-renderer gates, run_gl_renderer.sh).  It declares no GL itself: UXGL.xc's calls compile two
// shaders, link them, fill a buffer, set up a vertex array and draw a triangle over a cleared frame,
// then read the middle pixel back.  On win64 the calls go through UXGL's forwarders (opengl32 links
// none of them); elsewhere they are the platform's own.  The shading language follows glKind.
#import <Stdio.xc>
#import "UXPlatform.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXGeometry.xc"
#import "UXGL.xc"
#import "UXImage.xc"

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
u32 shader(u32 kind, u8* src)
    {
    u32 s = glCreateShader(kind);
    u8* srcs[1];
    srcs[0] = src;
    glShaderSource(s, (i32)1, &srcs[0], (i32*)0);
    glCompileShader(s);
    i32 ok = (i32)0;
    glGetShaderiv(s, (u32)$8B81, &ok); // GL_COMPILE_STATUS
    if (ok == (i32)0)
        {
        u8 log[512];
        i32 n = (i32)0;
        glGetShaderInfoLog(s, (i32)511, &n, &log[0]);
        log[n] = (u8)0;
        Stdio.printf("  (shader log: %s)\n", &log[0]);
        }
    return s;
    }
// As an app runs: the window made in applicationDidStart, the frame drawn on a later turn of the
// frame clock, when the platform has laid the window out.
UXApplication* gApp3;
UXGLView* gMap;
i32 gTurn;
void drawFrame(UXGLView* map);
void turn(void)
    {
    gTurn = gTurn + (i32)1;
    if (gTurn == (i32)5)
        {
        drawFrame(gMap);
        gApp3.stop();
        }
    }
class Delegate : Object<UXApplicationDelegate>
    {
    i32 applicationDidStart(UXApplication* app)
        {
        UXWindow* win = new UXWindow();
        UXView* canvas = new UXView();
        UXGLView* map = new UXGLView();
        win.open((u8*)"renderer", UXGeom.make((i16)60, (i16)60, (i16)200, (i16)200), canvas);
        canvas.addSubview(map, UXGeom.make((i16)0, (i16)0, (i16)200, (i16)200));
        app.addWindow(win);
        win.displayAll();
        gMap = map;
        app.everyTurn(&turn, (i32)20);
        return (i32)0;
        }
    }
void main(void)
    {
    gFails = (i32)0;
    UXApplication* app = new UXApplication();
    gApp3 = app;
    app.setDriver(UXPlatform.driver());
    app.setHeadless(true);
    app.setDelegate(new Delegate());
    app.run();
    if (gTurn < (i32)5)
        {
        Stdio.printf("FAIL: the frame clock never came round\n");
        }
    }
void drawFrame(UXGLView* map)
    {
    ck((u8*)"a context was made", map.makeGL());
    {
    typedef u8* GetStrFn(u32 which);
    GetStrFn* gs = (GetStrFn*)gDriver.glProc((u8*)"glGetString");
    Stdio.printf("  (GL %s / GLSL %s)\n", gs != (GetStrFn*)0 ? gs((u32)$1F02) : (u8*)"?", gs != (GetStrFn*)0 ? gs((u32)$8B8C) : (u8*)"?");
#if ARCH_win64
    // a GL 3.2 renderer needs vertex arrays: a context without them (Wine on macOS offers 2.1) cannot
    // run it, and that is the platform's answer, not this test's
    if (gDriver.glProc((u8*)"glGenVertexArrays") == (pointer)0)
        {
        Stdio.printf("SKIP: this context has no GL 3 (no vertex arrays)\n");
        gFails = (i32)-1000;
        return;
        }
#endif
    }
    bool es = map.glKind() == (i32)UX_GL_GLES3 || map.glKind() == (i32)UX_GL_WEBGL2;
    u8* vs = es ? (u8*)"#version 300 es\nin vec2 p;\nvoid main(){gl_Position=vec4(p,0.0,1.0);}\n"
                : (u8*)"#version 150\nin vec2 p;\nvoid main(){gl_Position=vec4(p,0.0,1.0);}\n";
    u8* fs = es ? (u8*)"#version 300 es\nprecision mediump float;\nuniform vec4 tint;\nout vec4 o;\nvoid main(){o=tint;}\n"
                : (u8*)"#version 150\nuniform vec4 tint;\nout vec4 o;\nvoid main(){o=tint;}\n";
    u32 prog = glCreateProgram();
    glAttachShader(prog, shader((u32)$8B31, vs)); // GL_VERTEX_SHADER
    glAttachShader(prog, shader((u32)$8B30, fs)); // GL_FRAGMENT_SHADER
    glLinkProgram(prog);
    i32 linked = (i32)0;
    glGetProgramiv(prog, (u32)$8B82, &linked); // GL_LINK_STATUS
    ck((u8*)"the shaders compile and link", linked != (i32)0);
    glUseProgram(prog);
    float tri[6];
    tri[0] = -0.9; tri[1] = -0.9; tri[2] = 0.9; tri[3] = -0.9; tri[4] = 0.0; tri[5] = 0.9;
    u32 vao = (u32)0;
    u32 vbo = (u32)0;
    glGenVertexArrays((i32)1, &vao);
    glBindVertexArray(vao);
    glGenBuffers((i32)1, &vbo);
    glBindBuffer((u32)$8892, vbo); // GL_ARRAY_BUFFER
    glBufferData((u32)$8892, (i64)24, (pointer)&tri[0], (u32)$88E4); // GL_STATIC_DRAW
    i32 at = glGetAttribLocation(prog, (u8*)"p");
    glEnableVertexAttribArray((u32)at);
    glVertexAttribPointer((u32)at, (i32)2, (u32)$1406, (u8)0, (i32)8, (pointer)0); // GL_FLOAT
    float tint[4];
    tint[0] = 0.9; tint[1] = 0.6; tint[2] = 0.1; tint[3] = 1.0;
    glUniform4fv(glGetUniformLocation(prog, (u8*)"tint"), (i32)1, &tint[0]);
    glClearColor(0.1, 0.2, 0.3, 1.0);
    glClear((u32)$4000);
    glDrawArrays((u32)$0004, (i32)0, (i32)3); // GL_TRIANGLES
    glFinish();
    map.presentGL();
    // the frame as presented, through the neutral read (glReadPixels cannot read a multisampled
    // framebuffer, and AppKit's is one): its middle is the triangle, its corner the cleared colour
    UXImage* f = map.snapshot();
    u32 mid = f != (UXImage*)0 ? f.px[(f.h / (i32)2) * f.w + f.w / (i32)2] : (u32)0;
    u32 cor = f != (UXImage*)0 ? f.px[(i32)2 * f.w + (i32)2] : (u32)0;
    i32 mr = (i32)((mid >> (u32)16) & (u32)255);
    i32 mg = (i32)((mid >> (u32)8) & (u32)255);
    i32 mb = (i32)(mid & (u32)255);
    i32 cr = (i32)((cor >> (u32)16) & (u32)255);
    i32 cb = (i32)(cor & (u32)255);
    Stdio.printf("  (%s, GL kind %d: middle %d %d %d, corner %d .. %d, error %d)\n", UXPlatform.name(), map.glKind(), mr, mg, mb, cr, cb, (i32)glGetError());
    ck((u8*)"the frame reads back", f != (UXImage*)0);
    ck((u8*)"the triangle is drawn in its tint", mr > (i32)210 && mg > (i32)135 && mg < (i32)170 && mb < (i32)50);
    ck((u8*)"...over the cleared frame", cr < (i32)40 && cb > (i32)60 && cb < (i32)90);
    glDeleteBuffers((i32)1, &vbo);
    glDeleteVertexArrays((i32)1, &vao);
    glDeleteProgram(prog);
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: a GL 3.2 renderer through UXGL, the same source on %s\n", UXPlatform.name());
        }
    else
        {
        Stdio.printf("FAIL: %d on %s\n", gFails, UXPlatform.name());
        }
    }
