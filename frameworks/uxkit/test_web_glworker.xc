// test_web_glworker.xc — WebGL2 in the worker run loop (the web-glworker gate, real headless Chrome).
// A worker has no DOM, so a GL view there is an OffscreenCanvas of its own, and each present
// composites the GL views under the 2-D layer into the one frame the worker posts to the page.  The
// app makes a GL view with a 2-D view over it, clears the GL to a colour only this run uses through
// the GLES 3 calls a renderer declares (bound to WebGL2 as host imports), draws the left half green
// with a shader, presents, and tells the page; the page reads the frame on its display canvas: the
// clear colour on the right, the drawn green on the left, the 2-D view's red over the map.
#import <Stdio.xc>
#import "UXWebDriver.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXEvent.xc"

// GLES 3, as a renderer declares it (renderer.xc's shape): the web binds these as host imports
void glClearColor(float r, float g, float b, float a);
void glClear(u32 mask);
u32 glGetError();
u32 glCreateShader(u32 type);
void glShaderSource(u32 shader, i32 count, pointer text, pointer length);
void glCompileShader(u32 shader);
void glGetShaderiv(u32 shader, u32 pname, i32* out);
u32 glCreateProgram();
void glAttachShader(u32 prog, u32 shader);
void glLinkProgram(u32 prog);
void glGetProgramiv(u32 prog, u32 pname, i32* out);
void glUseProgram(u32 prog);
i32 glGetUniformLocation(u32 prog, u8* name);
void glUniform4f(i32 loc, float x, float y, float z, float w);
void glGenBuffers(i32 n, u32* out);
void glBindBuffer(u32 target, u32 id);
void glBufferData(u32 target, i64 bytes, pointer data, u32 usage);
void glGenVertexArrays(i32 n, u32* out);
void glBindVertexArray(u32 id);
void glEnableVertexAttribArray(u32 index);
void glVertexAttribPointer(u32 index, i32 size, u32 type, u8 normalized, i32 stride, pointer offset);
void glDrawArrays(u32 mode, i32 first, i32 count);
u8* glGetString(u32 name);

u32 shader(u32 type, u8* src)
    {
    u32 s = glCreateShader(type);
    pointer srcs[1];
    srcs[0] = (pointer)src;
    glShaderSource(s, (i32)1, (pointer)&srcs[0], (pointer)0);
    glCompileShader(s);
    i32 ok = (i32)0;
    glGetShaderiv(s, (u32)$8B81, &ok); // GL_COMPILE_STATUS
    Stdio.printf("shader %d compiled=%d\n", (i32)type, ok);
    return s;
    }

class MapView : UXGLView
    {
    i32 painted;
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        painted = painted + (i32)1;
        }
    }
class OverView : UXView
    {
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRectRGB(self.bounds(), (i32)230, (i32)20, (i32)20);
        }
    }

void main(void)
    {
    UXWebDriver* d = new UXWebDriver();
    gDriver = d;
    i32 sw = (i32)0;
    i32 sh = (i32)0;
    d.boot(&sw, &sh);
    UXView* canvas = new UXView();
    UXWindow* win = new UXWindow();
    win.open((u8*)"gl", UXGeom.make((i16)0, (i16)0, (i16)240, (i16)160), canvas);
    MapView* map = new MapView();
    canvas.addSubview(map, UXGeom.make((i16)0, (i16)0, (i16)240, (i16)160));
    OverView* over = new OverView();
    canvas.addSubview(over, UXGeom.make((i16)100, (i16)60, (i16)40, (i16)40)); // after the map: over it
    win.displayAll();
    bool made = map.makeGL();
    Stdio.printf("gl made=%d kind=%d\n", made ? (i32)1 : (i32)0, map.glKind());
    if (!made)
        {
        Stdio.printf("FAIL: no WebGL2 context in the worker\n");
        return;
        }
    Stdio.printf("GL_VERSION %s\n", glGetString((u32)$1F02));
    glClearColor(0.25, 0.5, 0.75, 1.0);
    glClear((u32)$4000);
    // a real draw: two triangles over the LEFT half, in a uniform green
    u32 vs = shader((u32)$8B31, (u8*)"#version 300 es\nin vec2 p;\nvoid main() { gl_Position = vec4(p, 0.0, 1.0); }\n");
    u32 fs = shader((u32)$8B30, (u8*)"#version 300 es\nprecision mediump float;\nuniform vec4 col;\nout vec4 o;\nvoid main() { o = col; }\n");
    u32 prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    i32 linked = (i32)0;
    glGetProgramiv(prog, (u32)$8B82, &linked); // GL_LINK_STATUS
    Stdio.printf("program linked=%d\n", linked);
    float quad[12];
    quad[0] = -1.0; quad[1] = -1.0; quad[2] = 0.0; quad[3] = -1.0; quad[4] = 0.0; quad[5] = 1.0;
    quad[6] = -1.0; quad[7] = -1.0; quad[8] = 0.0; quad[9] = 1.0; quad[10] = -1.0; quad[11] = 1.0;
    u32 vao = (u32)0;
    glGenVertexArrays((i32)1, &vao);
    glBindVertexArray(vao);
    u32 vbo = (u32)0;
    glGenBuffers((i32)1, &vbo);
    glBindBuffer((u32)$8892, vbo); // GL_ARRAY_BUFFER
    glBufferData((u32)$8892, (i64)48, (pointer)&quad[0], (u32)$88E4); // STATIC_DRAW
    glEnableVertexAttribArray((u32)0);
    glVertexAttribPointer((u32)0, (i32)2, (u32)$1406, (u8)0, (i32)8, (pointer)0); // FLOAT
    glUseProgram(prog);
    glUniform4f(glGetUniformLocation(prog, (u8*)"col"), 0.125, 0.75, 0.25, 1.0);
    glDrawArrays((u32)4, (i32)0, (i32)6); // GL_TRIANGLES
    map.presentGL();
    win.displayAll();
    // a turn of the loop presents the 2-D layer (on the web it is drawn at the present), which the
    // worker composites over the GL frame -- an app's run loop does this every turn
    UXEvent* ev = new UXEvent();
    d.pumpMessages((i32)0, ev);
    Stdio.printf(glGetError() == (u32)0 ? "PASS: WebGL2 in the worker -- a context, a frame, composited under the 2-D layer\n"
                                       : "FAIL: a GL error\n");
    }
