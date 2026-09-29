// renderer.xc — the GL renderer behind the seam, as the harness sees it.  The real
// one: upload a texture once, build one program once, and issue one draw per frame
// with positions, UVs and a per-vertex colour.
//
// WHAT THIS IS.  The smallest renderer that draws what the spike asks for, and no
// more than that on purpose.
//
// WHAT IT DELIBERATELY IS NOT, because a spike is the worst place to settle one of
// these: no camera and no matrix stack (the projection is one uniform and the
// harness hands over positions already in the window's own pixels); no batching, no
// atlas lookup, no mipmap policy, no mesh, no material, no passes, no framebuffers,
// no depth, no textures beyond the one.  Those are T2's L1 and they are decided by
// the map and the panel, not by a quad.
//
// THE ENTRY POINTS ARE LINKED, NOT LOADED.  On macOS the GL 3.3 core calls are
// exported by OpenGL.framework, so a bodyless declaration here binds at link time
// and the link line's -framework OpenGL is the entire loader.  Verified rather than
// assumed: a C program calling glGenVertexArrays, glCreateProgram and glDrawArrays
// links and launches against -framework OpenGL with no dlsym anywhere, so the loader
// the seam's comments anticipate is NOT needed on this backend.  It is real for
// Linux, Windows and the web (glXGetProcAddress, wglGetProcAddress, the EGL pair),
// and when it arrives it belongs to the BACKEND, not to a renderer: the seam hands
// us an opaque context and promises it is current on the calling thread, and that
// promise is what lets this file be a file about drawing.
//
// ONE SHADER SOURCE, as the plan asks.  GLSL ES 3.00 unchanged for GLES3 and WebGL2,
// and the same body with a `#version 330 core` preamble for the desktop core
// profile — which is why the source is CONCATENATED at init instead of written
// twice.  A shader that exists in two copies is a shader that will be edited in one
// of them.
//
// ONE UNIFORM, AND IT IS NOT A CAMERA.  uHalf is the viewport's half size, and it is
// what turns the harness's positions (pixels, y down, the same units the browser's
// camera already produces) into clip space.  The alternative is transforming every
// vertex on the CPU each frame, which is a pass the real client does not pay, and a
// spike that measures the wrong program is worse than no spike.
//
// `ctx` IS THE DRIVER'S TOKEN, used here for one thing: as the key of the state that
// belongs to a context.  GL objects are per-context, so a second view needs a table;
// the spike has one view, and a table with one row is a lie.
#import <Stdio.xc>
#import "UXViewDriver.xc"

// ── GL, with the constants written out ───────────────────────────────────────────
// Not a header: these values are ABI and have never moved, and a file that has to
// find the platform's GL headers is a file that does not compile on the next target.
// The cast is part of each name, so a call site reads as the call it is: the ones
// passed as a GLint are (i32) and everything else is (u32).
#define RB_TEXTURE_2D             (u32)0x0DE1
#define RB_TEXTURE_WRAP_S         (u32)0x2802
#define RB_TEXTURE_WRAP_T         (u32)0x2803
#define RB_TEXTURE_MAG_FILTER     (u32)0x2800
#define RB_TEXTURE_MIN_FILTER     (u32)0x2801
#define RB_CLAMP_TO_EDGE          (i32)0x812F
#define RB_REPEAT                 (i32)0x2901
#define RB_LINEAR                 (i32)0x2601
#define RB_LINEAR_MIPMAP_LINEAR   (i32)0x2703
#define RB_RGBA                   (u32)0x1908
#define RB_UNSIGNED_BYTE          (u32)0x1401
#define RB_UNPACK_ALIGNMENT       (u32)0x0CF5
#define RB_ARRAY_BUFFER           (u32)0x8892
#define RB_STREAM_DRAW            (u32)0x88E0
#define RB_FLOAT                  (u32)0x1406
#define RB_TRIANGLES              (u32)0x0004
#define RB_BLEND                  (u32)0x0BE2
#define RB_DEPTH_TEST             (u32)0x0B71
#define RB_CULL_FACE              (u32)0x0B44
#define RB_ONE                    (u32)1
#define RB_ONE_MINUS_SRC_ALPHA    (u32)0x0303
#define RB_COLOR_BUFFER_BIT       (u32)0x4000
#define RB_TEXTURE0               (u32)0x84C0
#define RB_VERTEX_SHADER          (u32)0x8B31
#define RB_FRAGMENT_SHADER        (u32)0x8B30
#define RB_COMPILE_STATUS         (u32)0x8B81
#define RB_LINK_STATUS            (u32)0x8B82
#define RB_VIEWPORT               (u32)0x0BA2

void glGenTextures(i32 n, u32* out);
void glBindTexture(u32 target, u32 tex);
void glTexParameteri(u32 target, u32 pname, i32 param);
void glTexImage2D(u32 target, i32 level, i32 internal, i32 w, i32 h, i32 border,
                  u32 format, u32 type, pointer pixels);
void glGenerateMipmap(u32 target);
void glPixelStorei(u32 pname, i32 param);
void glActiveTexture(u32 unit);
void glGenBuffers(i32 n, u32* out);
void glBindBuffer(u32 target, u32 id);
void glBufferData(u32 target, i64 bytes, pointer data, u32 usage);
void glGenVertexArrays(i32 n, u32* out);
void glBindVertexArray(u32 id);
void glEnableVertexAttribArray(u32 index);
void glVertexAttribPointer(u32 index, i32 size, u32 type, u8 normalized, i32 stride,
                           pointer offset);
u32  glCreateShader(u32 kind);
void glShaderSource(u32 shader, i32 count, pointer text, pointer length);
void glCompileShader(u32 shader);
void glGetShaderiv(u32 shader, u32 pname, i32* out);
void glGetShaderInfoLog(u32 shader, i32 max, i32* len, pointer log);
u32  glCreateProgram(void);
void glAttachShader(u32 prog, u32 shader);
void glLinkProgram(u32 prog);
void glGetProgramiv(u32 prog, u32 pname, i32* out);
void glGetProgramInfoLog(u32 prog, i32 max, i32* len, pointer log);
void glUseProgram(u32 prog);
i32  glGetUniformLocation(u32 prog, u8* name);
void glUniform2f(i32 loc, float x, float y);
void glUniform1i(i32 loc, i32 v);
void glDrawArrays(u32 mode, i32 first, i32 count);
void glGetIntegerv(u32 pname, i32* out);
void glEnable(u32 cap);
void glDisable(u32 cap);
void glBlendFunc(u32 src, u32 dst);
void glClearColor(float r, float g, float b, float a);
void glClear(u32 bits);

// ── the shader, once ─────────────────────────────────────────────────────────────
//
// Locations are bound in the source with layout(), so the attribute contract is
// visible where the attributes are used rather than three calls away.
//
// The fragment output is premultiplied and the blend is (ONE, ONE_MINUS_SRC_ALPHA),
// which is what gl.js does and what its atlas is: "the atlas is premultiplied" is a
// comment in that client's sprite shader, and a renderer that blended it as straight
// alpha would draw every soft edge the map has too light.  The spike's own sheet is
// opaque so the two agree to the pixel -- it is written this way so that the first
// real atlas through this path is already right.
u8* rbVsBody(void)
    {
    return (u8*)"layout(location = 0) in vec2 aPos;\n"
                "layout(location = 1) in vec2 aUV;\n"
                "layout(location = 2) in vec4 aCol;\n"
                "uniform vec2 uHalf;\n"
                "out vec2 vUV;\n"
                "out vec4 vCol;\n"
                "void main()\n"
                "    {\n"
                "    vUV = aUV;\n"
                "    vCol = aCol;\n"
                "    gl_Position = vec4(aPos.x / uHalf.x - 1.0, 1.0 - aPos.y / uHalf.y, 0.0, 1.0);\n"
                "    }\n";
    }
u8* rbFsBody(void)
    {
    return (u8*)"#ifdef GL_ES\n"
                "precision mediump float;\n"
                "#endif\n"
                "in vec2 vUV;\n"
                "in vec4 vCol;\n"
                "uniform sampler2D uTex;\n"
                "out vec4 fragColour;\n"
                "void main()\n"
                "    {\n"
                "    fragColour = texture(uTex, vUV) * vCol;\n"
                "    }\n";
    }

// ── the state, which is the context's ────────────────────────────────────────────
pointer gRbCtx = (pointer)0;
i32 gRbReady = (i32)0;          // 0 = not yet, 1 = ready, 2 = it cannot be built
i32 gRbWarnedViewport = (i32)0;
u32 gRbProg = (u32)0;
i32 gRbHalfLoc = (i32)-1;
i32 gRbTexLoc = (i32)-1;
u32 gRbVao = (u32)0;
u32 gRbVboPos = (u32)0;
u32 gRbVboUV = (u32)0;
u32 gRbVboCol = (u32)0;
i32 gRbViewW = (i32)0;
i32 gRbViewH = (i32)0;
i32 gRbDrawCalls = (i32)0;
i32 gRbBytesUploaded = (i32)0;

// The two source strings are joined here rather than written twice: see the note at
// the top.  A fixed buffer, because a shader source is a known-size thing and a
// malloc in an init path is a leak waiting for the day init runs twice.
u8 gRbSrc[4096];
u8* rbPreamble(void)
    {
    if (gDriver.glKind() == (i32)UX_GL_GL33)
        {
        return (u8*)"#version 330 core\n";
        }
    // GLES3 and WebGL2 both take ES 3.00, and both REQUIRE the version to be the
    // first line: a shader without one is ES 1.00, which is refused here on purpose
    // (the four programs are worth writing once, in one language).
    return (u8*)"#version 300 es\n";
    }
u8* rbJoin(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && i < (i32)4000)
        {
        gRbSrc[i] = a[i];
        i = i + (i32)1;
        }
    i32 j = (i32)0;
    while (b[j] != (u8)0 && i < (i32)4094)
        {
        gRbSrc[i] = b[j];
        i = i + (i32)1;
        j = j + (i32)1;
        }
    gRbSrc[i] = (u8)0;
    return &gRbSrc[0];
    }

// A shader that will not compile is not a thing to find later: the log is printed
// where it happened, once, and the renderer stops issuing anything.  The frame
// harness's own draw-call count is then 0, which is the same symptom as a renderer
// that never ran -- and the difference is this line.
u32 rbCompile(u32 kind, u8* body)
    {
    u32 sh = glCreateShader(kind);
    u8* src = rbJoin(rbPreamble(), body);
    glShaderSource(sh, (i32)1, (pointer)&src, (pointer)0);
    glCompileShader(sh);
    i32 ok = (i32)0;
    glGetShaderiv(sh, RB_COMPILE_STATUS, &ok);
    if (ok == (i32)0)
        {
        u8 log[1024];
        i32 n = (i32)0;
        log[0] = (u8)0;
        glGetShaderInfoLog(sh, (i32)1000, &n, &log[0]);
        Stdio.printf("renderer: the shader will not compile:\n%s\n", &log[0]);
        gRbReady = (i32)2;
        }
    return sh;
    }

void rbInit(pointer ctx)
    {
    if (gRbReady != (i32)0 && gRbCtx == ctx)
        {
        return;
        }
    if (gRbReady == (i32)2)
        {
        return;
        }
    gRbCtx = ctx;
    gRbReady = (i32)0;

    // Most of what a map needs is what a map must NOT have: no depth, no culling,
    // blending on.  Stated here because a renderer is read for its state.
    glDisable(RB_DEPTH_TEST);
    glDisable(RB_CULL_FACE);
    glEnable(RB_BLEND);
    glBlendFunc(RB_ONE, RB_ONE_MINUS_SRC_ALPHA);
    glPixelStorei(RB_UNPACK_ALIGNMENT, (i32)1);   // an atlas need not be a multiple of 4 wide

    glGenVertexArrays((i32)1, &gRbVao);
    glBindVertexArray(gRbVao);
    // Three buffers rather than one interleaved: the arrays arrive separate, and the
    // interleaving question is part of the batching design this spike must not make.
    glGenBuffers((i32)1, &gRbVboPos);
    glGenBuffers((i32)1, &gRbVboUV);
    glGenBuffers((i32)1, &gRbVboCol);
    glBindBuffer(RB_ARRAY_BUFFER, gRbVboPos);
    glEnableVertexAttribArray((u32)0);
    glVertexAttribPointer((u32)0, (i32)2, RB_FLOAT, (u8)0, (i32)8, (pointer)0);
    glBindBuffer(RB_ARRAY_BUFFER, gRbVboUV);
    glEnableVertexAttribArray((u32)1);
    glVertexAttribPointer((u32)1, (i32)2, RB_FLOAT, (u8)0, (i32)8, (pointer)0);
    // The colour is a u32 per vertex, 0xRRGGBBAA, and on a little-endian machine the
    // bytes in memory are therefore R, G, B, A -- which is what normalised GL_UNSIGNED_BYTE
    // wants.  The harness only ever passes 0xFFFFFFFF; the convention is written down
    // because the first tint that goes through here will need it.
    glBindBuffer(RB_ARRAY_BUFFER, gRbVboCol);
    glEnableVertexAttribArray((u32)2);
    glVertexAttribPointer((u32)2, (i32)4, RB_UNSIGNED_BYTE, (u8)1, (i32)4, (pointer)0);

    u32 vs = rbCompile(RB_VERTEX_SHADER, rbVsBody());
    u32 fs = rbCompile(RB_FRAGMENT_SHADER, rbFsBody());
    gRbProg = glCreateProgram();
    glAttachShader(gRbProg, vs);
    glAttachShader(gRbProg, fs);
    glLinkProgram(gRbProg);
    i32 linked = (i32)0;
    glGetProgramiv(gRbProg, RB_LINK_STATUS, &linked);
    if (linked == (i32)0)
        {
        u8 log[1024];
        i32 n = (i32)0;
        log[0] = (u8)0;
        glGetProgramInfoLog(gRbProg, (i32)1000, &n, &log[0]);
        Stdio.printf("renderer: the program will not link:\n%s\n", &log[0]);
        gRbReady = (i32)2;
        return;
        }
    glUseProgram(gRbProg);
    gRbHalfLoc = glGetUniformLocation(gRbProg, (u8*)"uHalf");
    gRbTexLoc = glGetUniformLocation(gRbProg, (u8*)"uTex");
    gRbReady = (i32)1;

    // One line, so the log says what was measured: which call set the driver answered
    // with, and how big the DRAWING BUFFER is.  T0's number is a comparison against a
    // browser on the same machine, and a comparison without the device ratio beside it
    // is not one -- and the ratio shows in the buffer, not in the window.
    i32 vp0[4];
    vp0[0] = (i32)0; vp0[1] = (i32)0; vp0[2] = (i32)0; vp0[3] = (i32)0;
    glGetIntegerv(RB_VIEWPORT, &vp0[0]);
    Stdio.printf("renderer: glKind=%d, drawing buffer %d x %d\n", gDriver.glKind(),
                 vp0[2], vp0[3]);
    }

// ── the three calls, and the two counters ────────────────────────────────────────

i32 rb_texture(pointer ctx, i32 w, i32 h, u8* rgba, bool repeat, bool mips)
    {
    rbInit(ctx);
    if (gRbReady != (i32)1)
        {
        return (i32)0;
        }
    u32 tex = (u32)0;
    glGenTextures((i32)1, &tex);
    glActiveTexture(RB_TEXTURE0);
    glBindTexture(RB_TEXTURE_2D, tex);
    if (repeat)
        {
        glTexParameteri(RB_TEXTURE_2D, RB_TEXTURE_WRAP_S, RB_REPEAT);
        glTexParameteri(RB_TEXTURE_2D, RB_TEXTURE_WRAP_T, RB_REPEAT);
        }
    else
        {
        glTexParameteri(RB_TEXTURE_2D, RB_TEXTURE_WRAP_S, RB_CLAMP_TO_EDGE);
        glTexParameteri(RB_TEXTURE_2D, RB_TEXTURE_WRAP_T, RB_CLAMP_TO_EDGE);
        }
    glTexParameteri(RB_TEXTURE_2D, RB_TEXTURE_MAG_FILTER, RB_LINEAR);
    if (mips)
        {
        glTexParameteri(RB_TEXTURE_2D, RB_TEXTURE_MIN_FILTER, RB_LINEAR_MIPMAP_LINEAR);
        }
    else
        {
        glTexParameteri(RB_TEXTURE_2D, RB_TEXTURE_MIN_FILTER, RB_LINEAR);
        }
    glTexImage2D(RB_TEXTURE_2D, (i32)0, (i32)RB_RGBA, w, h, (i32)0, RB_RGBA,
                 RB_UNSIGNED_BYTE, (pointer)rgba);
    if (mips)
        {
        glGenerateMipmap(RB_TEXTURE_2D);
        }
    // TEXTURE bytes, and only those: it is the number T0 asks for ("bytes of texture
    // uploaded at startup"), and the per-frame buffer traffic is in the frame time
    // already.  A counter that added both would answer neither question.
    gRbBytesUploaded = gRbBytesUploaded + w * h * (i32)4;
    return (i32)tex;
    }

void rb_bind(pointer ctx, i32 handle)
    {
    rbInit(ctx);
    if (gRbReady != (i32)1)
        {
        return;
        }
    glUseProgram(gRbProg);
    glActiveTexture(RB_TEXTURE0);
    glBindTexture(RB_TEXTURE_2D, (u32)handle);
    glBindVertexArray(gRbVao);

    // The viewport IS the drawing buffer, in pixels, and the DRIVER owns it -- it owns
    // the surface, so it owns the one number that says how big the surface is.  The
    // renderer reads it rather than assuming a size, which is what makes the harness's
    // positions (points, y down) land on the same pixels at any device ratio: at 2x
    // the viewport is twice the window and the map still fills it.
    i32 vp[4];
    vp[0] = (i32)0; vp[1] = (i32)0; vp[2] = (i32)0; vp[3] = (i32)0;
    glGetIntegerv(RB_VIEWPORT, &vp[0]);
    gRbViewW = vp[2];
    gRbViewH = vp[3];
    if (gRbViewW <= (i32)0 || gRbViewH <= (i32)0)
        {
        if (gRbWarnedViewport == (i32)0)
            {
            gRbWarnedViewport = (i32)1;
            Stdio.printf("renderer: the GL viewport is empty (%d x %d), so nothing is drawn; "
                         "the driver has not sized the surface\n", gRbViewW, gRbViewH);
            }
        return;
        }
    glUniform2f(gRbHalfLoc, (float)gRbViewW * 0.5, (float)gRbViewH * 0.5);
    if (gRbTexLoc >= (i32)0)
        {
        glUniform1i(gRbTexLoc, (i32)0);
        }
    }

void rb_draw(pointer ctx, float* verts, float* uvs, u32* colours, i32 count)
    {
    if (count <= (i32)0)
        {
        return;
        }
    rbInit(ctx);
    if (gRbReady != (i32)1 || gRbViewW <= (i32)0 || gRbViewH <= (i32)0)
        {
        return;
        }
    // Streamed every frame, not cached: the harness mutates the positions for the
    // moving case, and a renderer that decided an array had not changed would report a
    // frame time for a frame it did not draw.
    glBindBuffer(RB_ARRAY_BUFFER, gRbVboPos);
    glBufferData(RB_ARRAY_BUFFER, (i64)count * (i64)8, (pointer)verts, RB_STREAM_DRAW);
    glBindBuffer(RB_ARRAY_BUFFER, gRbVboUV);
    glBufferData(RB_ARRAY_BUFFER, (i64)count * (i64)8, (pointer)uvs, RB_STREAM_DRAW);
    glBindBuffer(RB_ARRAY_BUFFER, gRbVboCol);
    glBufferData(RB_ARRAY_BUFFER, (i64)count * (i64)4, (pointer)colours, RB_STREAM_DRAW);

    // One clear per frame, before the draw: a double-buffered swap alternates two
    // buffers, and the frame that gets dumped has to be this frame and not the other
    // one's leftovers.
    glClearColor(0.05, 0.06, 0.08, 1.0);
    glClear(RB_COLOR_BUFFER_BIT);

    glDrawArrays(RB_TRIANGLES, (i32)0, count);
    gRbDrawCalls = gRbDrawCalls + (i32)1;
    }

i32 rb_stats_drawCalls(void)
    {
    return gRbDrawCalls;
    }
i32 rb_stats_bytesUploaded(void)
    {
    return gRbBytesUploaded;
    }
void rb_stats_reset(void)
    {
    gRbDrawCalls = (i32)0;
    }
