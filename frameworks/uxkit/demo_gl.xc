// demo_gl.xc — the frame-time harness for the GL seam (T0's instrument).
//
// WHAT THIS IS.  A real window, a real GL surface, and a map drawn through the seam:
// texture uploaded once, one draw call per frame, present once per frame, and the
// frame time measured over 600 frames after 60 warm-up frames, p50 and p95, on a
// still camera and a moving one, with the overlay off and on.
//
// WHAT THIS IS NOT, and it is worth writing down before the first number is believed:
//
//   - it does not settle the atlas format, a compression scheme, the Rocks binding,
//     the view tree, or the event loop.  Each has a track later in the plan that owns
//     it, and a spike is the worst place to settle one.
//   - THE FRAME IS DRIVEN BY a bounded loop inside the app's start turn, and here is
//     the loop: `runConfig` steps a frame counter, draws, presents and stops.  That
//     is stated so the number can be reproduced, not as a proposal for how a real
//     client paces itself -- the driver owns the pacing (UXViewDriver.xc: presentGL).
//   - the overlay is a UXLabel over the GL view, so the 2D-over-map question is
//     answered by the TREE and not by the renderer.  On AppKit the label is a native
//     NSView above the surface and both are composited in one turn.
//
// The renderer is renderer.xc: the app's side of the seam, and the file the real
// client's renderer replaces.  The PNG dumps are what say what a frame actually
// held, and there are two of them because they answer two different questions:
// the map alone is read back from the SURFACE (ux_ak_gl_grab) and the overlay is
// drawn from the toolkit's view tree (ux_ak_gl_grab_window), which is where the text
// over the map lives.  The surface dump holds the map and no text; the view dump holds
// the text and no map, because a composited surface is not part of a view's bitmap.
// Between them, each half of "map with text" is falsifiable.
#import <Stdio.xc>
#import "UXAppKitDriver.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"
#import "UXPng.xc"
#import "renderer.xc"
#import "demo_autoquit.xc"

// The shim's frame dump.  Reading a frame off the drawable is the driver's job (it
// owns the surface) and it is not part of the drawing seam, so it is declared here
// rather than grown into the protocol for a benchmark -- the same shape as
// demo_autoquit.xc's ux_ak_close_after_ms.
i32 ux_ak_gl_grab(pointer peer, u8* path);
// The drawable in pixels against the view in points, so the ratio this run was
// measured at is STATED and not assumed: fills out with {pointW, pointH, pixelW, pixelH}.
i32 ux_ak_gl_backing(pointer peer, i32* out4);
// How many samples the GL context's framebuffer carries: the 4x the surface asks for, or 0
// if it fell back to a pixel format without sample buffers.  Printed so the edge quality is
// a measured number and not a claim.
i32 ux_ak_gl_samples(pointer peer);
// A view's whole window drawn through AppKit: the 2D views, their text and their
// order.  The GL view contributes its software fallback there and not its surface,
// which is the point of taking both pictures.
i32 ux_ak_gl_grab_window(pointer peer, u8* path);
// How many pixels in the last grab differ from its top-left pixel.  A blank dump reads
// 0; the map reads thousands, a line of text reads hundreds -- so the two dumps are
// CHECKED to hold what they claim and not merely to have been written.
i32 ux_ak_gl_grab_marks(void);
// The environment and whole-file reads, so the harness can take an input PATH (the real
// atlas) at run time without a path living in the source.  ux_ak_env never returns null.
u8* ux_ak_env(u8* name);
i32 ux_ak_file_size(u8* path);
i32 ux_ak_read_file(u8* path, u8* buf, i32 cap);

#define GLB_WARMUP 60
#define GLB_FRAMES 600
#define GLB_CELL 32    // a cell is one map hex at the default zoom
#define GLB_GRID_W 40
#define GLB_GRID_H 26

i32 gFails = 0;
void ck(bool ok, u8* what)
    {
    if (!ok)
        {
        Stdio.printf("  no: %s\n", what);
        gFails = gFails + 1;
        }
    }

// The procedural sheet: 192x192, a 12x12 grid of 16-pixel cells, each a flat colour
// inside a 2-pixel border of a contrasting one.  NPOT and un-mipmapped, like the real
// atlas, so the sampler case is the real one -- and the border is what makes a wrong
// sub-rect or a REPEAT sampler visible at a glance instead of plausible.
u8* gSheet = (u8*)0;
i32 gSheetW = (i32)192;
i32 gSheetH = (i32)192;

void buildSheet(void)
    {
    gSheet = (u8*)malloc((u32)(192 * 192 * 4));
    gSheetW = (i32)192;
    gSheetH = (i32)192;
    for (i32 y = (i32)0; y < (i32)192; y = y + (i32)1)
        {
        for (i32 x = (i32)0; x < (i32)192; x = x + (i32)1)
            {
            i32 cx = x / (i32)16;
            i32 cy = y / (i32)16;
            i32 lx = x - cx * (i32)16;
            i32 ly = y - cy * (i32)16;
            bool border = lx < (i32)2 || lx >= (i32)14 || ly < (i32)2 || ly >= (i32)14;
            i32 o = (y * (i32)192 + x) * (i32)4;
            u8 r = (u8)(40 + (cx * 17) % 200);
            u8 g = (u8)(40 + (cy * 23) % 200);
            u8 b = (u8)(40 + ((cx + cy) * 11) % 200);
            if (border)
                {
                r = (u8)(255 - r);
                g = (u8)(255 - g);
                b = (u8)(255 - b);
                }
            gSheet[o] = r;
            gSheet[o + 1] = g;
            gSheet[o + 2] = b;
            gSheet[o + 3] = (u8)255;
            }
        }
    }

// The real atlas, when one is pointed at: UX_GL_ATLAS is a path to a PNG, and it is
// decoded HERE with the toolkit's own decoder -- the same code path the app takes, not
// a host shortcut -- so the spike proves the real image uploads through the seam.  The
// geometry below still samples a stand-in grid until the client's camera arrives; the
// sheet and the camera are separate inputs and this is the sheet's.  No atlas path, or
// one that will not read, leaves the procedural sheet in place.
bool loadAtlas(void)
    {
    u8* path = ux_ak_env((u8*)"UX_GL_ATLAS");
    if (path == (u8*)0 || path[0] == (u8)0)
        {
        return false;
        }
    i32 n = ux_ak_file_size(path);
    if (n <= (i32)0)
        {
        Stdio.printf("atlas: cannot read %s\n", path);
        return false;
        }
    u8* bytes = (u8*)malloc((u32)n);
    i32 got = ux_ak_read_file(path, bytes, n);
    if (got != n)
        {
        Stdio.printf("atlas: read %d of %d bytes\n", got, n);
        return false;
        }
    UXImage* im = UXPng.decode(bytes, n);
    if (im == (UXImage*)0)
        {
        Stdio.printf("atlas: %s did not decode\n", path);
        return false;
        }
    i32 w = im.width();
    i32 h = im.height();
    // The decoder hands back 0xAARRGGBB words; GL wants RGBA BYTES, so the channels are
    // unpacked here and not reinterpreted.
    gSheet = (u8*)malloc((u32)(w * h * 4));
    for (i32 i = (i32)0; i < w * h; i = i + (i32)1)
        {
        u32 p = im.px[i];
        gSheet[i * (i32)4] = (u8)((p >> (u32)16) & (u32)0xFF);
        gSheet[i * (i32)4 + 1] = (u8)((p >> (u32)8) & (u32)0xFF);
        gSheet[i * (i32)4 + 2] = (u8)(p & (u32)0xFF);
        gSheet[i * (i32)4 + 3] = (u8)((p >> (u32)24) & (u32)0xFF);
        }
    gSheetW = w;
    gSheetH = h;
    Stdio.printf("atlas: %s decoded, %dx%d\n", path, w, h);
    return true;
    }

// The map: one quad per hex, as two triangles, so six vertices each.  The hexagon
// tessellation itself is the renderer's L0 and is not settled here.
float* gVerts = (float*)0;
float* gUvs = (float*)0;
u32* gColours = (u32*)0;
i32 gVertCount = 0;

void buildGeometry(void)
    {
    i32 quads = GLB_GRID_W * GLB_GRID_H;
    gVertCount = quads * (i32)6;
    gVerts = (float*)malloc((u32)(gVertCount * (i32)2 * (i32)4));
    gUvs = (float*)malloc((u32)(gVertCount * (i32)2 * (i32)4));
    gColours = (u32*)malloc((u32)(gVertCount * (i32)4));
    i32 v = (i32)0;
    for (i32 gy = (i32)0; gy < GLB_GRID_H; gy = gy + (i32)1)
        {
        for (i32 gx = (i32)0; gx < GLB_GRID_W; gx = gx + (i32)1)
            {
            float x0 = (float)(gx * GLB_CELL);
            float y0 = (float)(gy * GLB_CELL);
            float x1 = (float)(gx * GLB_CELL + GLB_CELL);
            float y1 = (float)(gy * GLB_CELL + GLB_CELL);
            // One atlas cell: cell (gx, gy) of the 12x12 sheet.
            float u0 = (float)((gx % 12) * 16) / 192.0;
            float v0 = (float)((gy % 12) * 16) / 192.0;
            float u1 = u0 + 16.0 / 192.0;
            float v1 = v0 + 16.0 / 192.0;
            float px[12];
            float py[12];
            float pu[12];
            float pv[12];
            px[0] = x0; py[0] = y0; pu[0] = u0; pv[0] = v0;
            px[1] = x1; py[1] = y0; pu[1] = u1; pv[1] = v0;
            px[2] = x1; py[2] = y1; pu[2] = u1; pv[2] = v1;
            px[3] = x0; py[3] = y0; pu[3] = u0; pv[3] = v0;
            px[4] = x1; py[4] = y1; pu[4] = u1; pv[4] = v1;
            px[5] = x0; py[5] = y1; pu[5] = u0; pv[5] = v1;
            for (i32 k = (i32)0; k < (i32)6; k = k + (i32)1)
                {
                gVerts[v * (i32)2] = px[k];
                gVerts[v * (i32)2 + 1] = py[k];
                gUvs[v * (i32)2] = pu[k];
                gUvs[v * (i32)2 + 1] = pv[k];
                gColours[v] = (u32)0xFFFFFFFF;
                v = v + (i32)1;
                }
            }
        }
    }

// A camera offset applied to the built geometry: the moving case, so the numbers are
// not the same frame drawn twice.
void offsetGeometry(float dx, float dy)
    {
    for (i32 i = (i32)0; i < gVertCount; i = i + (i32)1)
        {
        gVerts[i * (i32)2] = gVerts[i * (i32)2] + dx;
        gVerts[i * (i32)2 + 1] = gVerts[i * (i32)2 + 1] + dy;
        }
    }

// p50 / p95 of an unsorted sample set.  Insertion sort: 600 samples, and it has to be
// the same code on every backend, so no qsort.
i32 gSamples[GLB_FRAMES];
void sortSamples(i32 n)
    {
    for (i32 i = (i32)1; i < n; i = i + (i32)1)
        {
        i32 v = gSamples[i];
        i32 j = i - (i32)1;
        while (j >= (i32)0 && gSamples[j] > v)
            {
            gSamples[j + 1] = gSamples[j];
            j = j - (i32)1;
            }
        gSamples[j + 1] = v;
        }
    }
i32 percentile(i32 n, i32 p)
    {
    i32 i = (n * p) / (i32)100;
    if (i >= n)
        {
        i = n - (i32)1;
        }
    return gSamples[i];
    }

    class GLMap : UXGLView
    {
    i32 painted;
    void init(void)
        {
        super.init();
        painted = (i32)0;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        // The software fallback.  On a backend with a context this never runs, which is
        // the seam's one rule; it is here so the same app is a picture on GEM too.
        painted = painted + (i32)1;
        }
    }

    class Controller : Object<UXApplicationDelegate>
    {
    UXApplication* app;
    UXWindow* win;
    GLMap* map;
    UXLabel* overlay;
    UXLabel* headline;
    i32 sheet; // the texture handle, handed back on every bind rather than assumed

    // One configuration: 60 warm-up frames then 600 timed ones, timing each frame from
    // the first renderer call to the present.
    void runConfig(u8* name, bool moving, bool text)
        {
        if (gFails > (i32)0)
            {
            return;
            }
        overlay.setHidden(!text);
        // One frame, counted: what the renderer actually issues is its business (a
        // batching one issues fewer than the harness asks for), so it is read back and
        // not assumed.
        rb_stats_reset();
        rb_bind(map.glContext(), self.sheet);
        rb_draw(map.glContext(), gVerts, gUvs, gColours, gVertCount);
        i32 calls = rb_stats_drawCalls();
        for (i32 i = (i32)0; i < GLB_WARMUP; i = i + (i32)1)
            {
            if (moving)
                {
                offsetGeometry(1.0, 0.5);
                }
            rb_bind(map.glContext(), self.sheet);
            rb_draw(map.glContext(), gVerts, gUvs, gColours, gVertCount);
            map.presentGL();
            }
        for (i32 i = (i32)0; i < GLB_FRAMES; i = i + (i32)1)
            {
            if (moving)
                {
                offsetGeometry(1.0, 0.5);
                }
            i32 t0 = gDriver.nowUs();
            rb_bind(map.glContext(), self.sheet);
            rb_draw(map.glContext(), gVerts, gUvs, gColours, gVertCount);
            map.presentGL();
            i32 t1 = gDriver.nowUs();
            gSamples[i] = t1 - t0;
            }
        sortSamples(GLB_FRAMES);
        Stdio.printf("== %s %s: p50 %d us, p95 %d us, %d draw call(s)/frame\n",
                     name, text ? (u8*)"+ text" : (u8*)"map only",
                     percentile(GLB_FRAMES, (i32)50), percentile(GLB_FRAMES, (i32)95), calls);
        }

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        UXView* canvas = new UXView();
        win = new UXWindow();
        win.open((u8*)"UXKit GL frame harness", UXGeom.make((i16)100, (i16)80, (i16)1280, (i16)832), canvas);

        map = new GLMap();
        canvas.addSubview(map, UXGeom.make((i16)0, (i16)0, (i16)1280, (i16)832));
        headline = new UXLabel();
        headline.setText((u8*)"the number over the map, in the same frame");
        canvas.addSubview(headline, UXGeom.make((i16)16, (i16)796, (i16)600, (i16)18));
        overlay = new UXLabel();
        overlay.setText((u8*)"7");
        canvas.addSubview(overlay, UXGeom.make((i16)320, (i16)400, (i16)32, (i16)18));
        win.displayAll();

        bool made = map.makeGL();
        ck(made, "a GL context was made");
        ck(map.glKind() != (i32)UX_GL_NONE, "the backend has GL");
        if (!made)
            {
            Stdio.printf("FAIL: %d\n", gFails);
            app.stop();
            return (i32)0;
            }
        // The upload, once, at startup: NPOT and un-mipmapped, like the real atlas.
        // This is the call the paper and the water need and the atlas must not have.
        self.sheet = rb_texture(map.glContext(), gSheetW, gSheetH, gSheet, false, false);
        ck(self.sheet != (i32)0, "the sheet uploaded");
        // The ratio the numbers below are measured at, stated rather than assumed: the
        // window is in points, the drawable in pixels, and on this backend they differ
        // by the backing scale, which is 1 unless the window is on a Retina display.
        i32 back[4];
        if (ux_ak_gl_backing((pointer)map, &back[0]) == (i32)1)
            {
            Stdio.printf("glKind=%d, %d hexes, sheet %dx%d (%d bytes uploaded)\n",
                         map.glKind(), GLB_GRID_W * GLB_GRID_H, gSheetW, gSheetH,
                         rb_stats_bytesUploaded());
            Stdio.printf("window %dx%d points, drawable %dx%d pixels, ratio %d.%02d\n",
                         back[0], back[1], back[2], back[3],
                         (back[2] / back[0]), ((back[2] * (i32)100) / back[0]) % (i32)100);
            }
        // The multisample request, read back off the GL itself: 4 means the sample-buffer
        // pixel format was accepted, 0 means it fell back to none.  A silent 0 is the one
        // outcome that would let the edge quality regress without anyone noticing.
        i32 samples = ux_ak_gl_samples((pointer)map);
        Stdio.printf("gl samples=%d\n", samples);
        ck(samples > (i32)0, "the GL context carries sample buffers (edge antialiasing)");

        // No vsync for the timed run: with a blocking swap the number is the refresh
        // rate and says nothing about the map.
        gDriver.glSetSwapInterval((i32)0);
        self.runConfig((u8*)"still", false, false);

        // The map alone, off the front buffer after a present, with the camera where it
        // started.  A dump from a framebuffer object proves the renderer can draw and
        // says nothing about whether the surface got it; a dump taken after the moving
        // configs would say nothing either, because the camera walks the geometry off
        // the surface and the picture comes back the clear colour, which is exactly
        // what a lying spike would look like.
        i32 grabbed = ux_ak_gl_grab((pointer)map, (u8*)"/tmp/gl_frame.png");
        Stdio.printf("frame dumped to /tmp/gl_frame.png: %d (%d marks)\n", grabbed,
                     ux_ak_gl_grab_marks());
        ck(grabbed == (i32)1, "the surface dump was written");
        ck(ux_ak_gl_grab_marks() > (i32)1000, "the surface dump holds a map, not a blank");

        self.runConfig((u8*)"still", false, true);

        // The same still frame with the overlay on, drawn from the view tree: this is the
        // dump that shows the TEXT (the labels), and the surface dump above is the one that
        // shows what the surface contains and this does not -- the map.
        i32 grabbed2 = ux_ak_gl_grab_window((pointer)map, (u8*)"/tmp/gl_frame_text.png");
        Stdio.printf("window dumped to /tmp/gl_frame_text.png: %d (%d marks)\n", grabbed2,
                     ux_ak_gl_grab_marks());
        ck(grabbed2 == (i32)1, "the window dump was written");
        ck(ux_ak_gl_grab_marks() > (i32)100, "the window dump holds the text, not a blank");

        self.runConfig((u8*)"moving", true, false);
        self.runConfig((u8*)"moving", true, true);

        app.stop();
        return (i32)0;
        }
    }

    void
    main(void)
    {
    UXAppKitDriver* d = new UXAppKitDriver();
    gDriver = d;
    d.setInteractive(true);
    Controller* c = new Controller();
    UXApplication* app = new UXApplication();
    d.attachApp(app);
    app.setDelegate(c);
    buildSheet();
    loadAtlas();
    buildGeometry();
    app.run();
    if (gFails == 0)
        {
        Stdio.printf("PASS: GL frame harness — four configurations timed, frame dumped\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", gFails);
        }
    }
