---
title: "A GPU Mandelbrot you can zoom (tutorial)"
description: "Build a UXKit window with a custom widget that computes a Mandelbrot set in a par block (on the GPU where there is one), zooms to a rectangle you drag, follows the window as it is resized, and remembers the way back in a breadcrumb."
---

This tutorial builds a window you can play with. A Mandelbrot set fills it; drag
a rectangle and the view zooms to that rectangle; resize the window and the set
is recomputed for the new shape; a breadcrumb along the top remembers every
step, so a click takes you back. The set is computed by a
[`par` block](/compiler/language/par/), so on a machine with a GPU the pixels
come from the GPU, and on one without them from the CPU's threads. Nothing is
designed in a file: the window is built in code. (Designing the same window in
Rocks is a later tutorial.)

The program is `website/site/examples/uxkit/mandelbrot.xc`, and the
`doc-examples` gate compiles it. You need xcc 0.74 or later. If you have not
built a UXKit program before, [Hello UX](/tutorials/hello-ux/) explains the
shape of one.

## What it uses

- A **custom view**: a plain [`UXView`](/compiler/api/uxkit/uxview/) has no look
  of its own, so `drawRect` paints it. That is where the picture goes.
- A **`par` block over a grid**: one work item per pixel, which the compiler
  runs on the GPU where it can.
- **Mouse tracking**: the press and the drag, then the release, give the
  rubber-band rectangle.
- A **[`UXBreadcrumb`](/compiler/api/uxkit/uxbreadcrumb/)** for the history, one
  segment a step, clicked to go back.
- **Autoresizing masks**: the breadcrumb stays at the top, the view takes the
  rest, and both follow the window.

## Imports and the pixel buffer

```c
#import <Stdio.xc>
#import "Par.xc"
#import "UXLibc.xc"
#import "UXPlatform.xc"
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXBreadcrumb.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXViewDriver.xc" // UX_ANCHOR_*, UX_FLEX_*
#import "Array.xc"

#define MAXW 1280 // the largest picture we compute
#define MAXH 800
#define MAXIT 256 // iterations per pixel before we call it "inside"

// The buffer a `par` block writes.  A GPU kernel has no heap and no objects, so
// the pixels go in one global array, read and written element by element.
// Row-major, 0xAARRGGBB.
u32 gPixels[MAXW * MAXH];

// One place on the plane: the centre and the width of the view, in the complex
// numbers.  The history is a list of these.
class Zoom : Object
{
    float cx;
    float cy;
    float span;
    u8* label;
    void init(void)
    {
        cx = 0.0f;
        cy = 0.0f;
        span = 0.0f;
        label = (u8*)"";
    }
}
```

`gPixels` is a global array, not a field, because a GPU kernel has no heap and
no objects: the pixels go in one flat array, filled element by element. The
array is `MAXW * MAXH` words of `0xAARRGGBB`, the layout
[`UXGraphics.drawPixels`](/compiler/api/uxkit/uxgraphics/) reads, and a `par`
block over that grid or a smaller one writes the front of it.

`Zoom` is one place on the plane: the centre and the width of the view, in the
complex numbers. The history is a list of them.

## The widget

```c
// The widget.  A plain UXView draws nothing of its own, so drawRect paints it;
// and a plain view is where the mouse arrives.
class FractalView : UXView
{
    float cx;
    float cy;
    float span;
    u32*  shown; // the last computed picture, handed to drawPixels
    i32   imgW;  // its size in pixels
    i32   imgH;
    bool  dirty; // the region or the size changed: recompute before the next draw

    bool dragging;
    i32  dx0;
    i32  dy0;
    i32  dx1;
    i32  dy1;

    callback zoomed void(FractalView* view);

    void init(void)
    {
        super.init();
        cx = -0.5f; // the whole set, more or less
        cy = 0.0f;
        span = 3.2f;
        shown = (u32*)0;
        imgW = (i32)0;
        imgH = (i32)0;
        dirty = true;
        dragging = false;
        dx0 = (i32)0;
        dy0 = (i32)0;
        dx1 = (i32)0;
        dy1 = (i32)0;
        zoomed = (callback void(FractalView* view))0;
    }
    void setOnZoomed(callback z void(FractalView* view))
    {
        zoomed = z;
    }

    // Ask to recompute and redraw: used when something outside changes the view.
    void markDirty(void)
    {
        dirty = true;
        self.setNeedsDisplay();
    }

    // The window resized us: recompute for the new size on the next draw.
    void setFrame(UXRect f)
    {
        dirty = true;
        super.setFrame(f);
    }
```

The view holds the region it is showing (`cx`, `cy`, `span`), the buffer it last
computed (`shown`, with its size), and a `dirty` flag. It also holds a callback,
so it can tell the app when a zoom happened; the app owns the history, so the
view asks rather than keeping one itself.

Two small methods matter. `markDirty` says the region changed and asks for a
redraw. `setFrame` is the resize: the window resize moves the view and calls
this, so the view marks itself dirty and the next paint recomputes for the new
size. A plain view is custom-drawn, so it is the view's own frame that changes
here, on every backend.

## The kernel: computing on the GPU

```c
    // ---- the pixels -------------------------------------------------------
    // Fill the buffer for the current region at the current size.  A `par` grid
    // runs the body once per pixel; the compiler turns it into a GPU kernel.
    void render(void)
    {
        i32 w = (i32)self.bounds().w;
        i32 h = (i32)self.bounds().h;
        if (w > (i32)MAXW) { w = (i32)MAXW; }
        if (h > (i32)MAXH) { h = (i32)MAXH; }
        if (w < (i32)1 || h < (i32)1)
        {
            return;
        }
        float vspan = span * (float)h / (float)w; // the plane's height for this window
        float minX = cx - span / 2.0f;
        float minY = cy - vspan / 2.0f;
        float stepPx = span / (float)w; // one pixel, in the plane
        float limit = 4.0f;
        par mandelbrot :grid((u32)w, (u32)h)
        {
            float cr = minX + ((float)par.x + 0.5f) * stepPx;
            float ci = minY + ((float)par.y + 0.5f) * stepPx;
            float zx = 0.0f;
            float zy = 0.0f;
            i32   it = (i32)0;
            while (it < (i32)MAXIT)
            {
                float zx2 = zx * zx;
                float zy2 = zy * zy;
                if (zx2 + zy2 > limit)
                {
                    break; // escaped
                }
                zy = 2.0f * zx * zy + ci;
                zx = zx2 - zy2 + cr;
                it = it + (i32)1;
            }
            u32 c;
            if (it >= (i32)MAXIT)
            {
                c = (u32)0xFF000000; // in the set: black
            }
            else
            {
                u32 t = (u32)it;
                c = (u32)0xFF000000 | (((t * (u32)9) & (u32)0xFF) << (u32)16)
                                    | (((t * (u32)5) & (u32)0xFF) << (u32)8)
                                    |  ((t * (u32)3) & (u32)0xFF);
            }
            gPixels[par.y * par.width + par.x] = c;
        }
        // Copy into a fresh buffer.  drawPixels may cache what it is handed by
        // its address, so the bytes it reads must not change under it.
        if (shown != (u32*)0)
        {
            free((pointer)shown);
        }
        u32 n = (u32)(w * h);
        shown = (u32*)malloc(n * (u32)4);
        for (u32 k = (u32)0; k < n; k = k + (u32)1)
        {
            shown[k] = gPixels[k];
        }
        imgW = w;
        imgH = h;
        dirty = false;
    }

    void drawRect(UXGraphics* g, UXRect dirtyRect)
    {
        UXRect b = self.bounds();
        if ((i32)b.w != imgW || (i32)b.h != imgH || dirty)
        {
            self.render();
        }
        if (shown != (u32*)0)
        {
            g.drawPixels((u8*)shown, imgW, imgH, (i32)UXPIX_ARGB32,
                         UXGeom.make((i16)0, (i16)0, (i16)imgW, (i16)imgH), b, (i32)255);
        }
        if (dragging)
        {
            g.fillRectRGB(self.selection(), (i32)255, (i32)255, (i32)0);
        }
    }
```

`render` does the arithmetic. It works out the plane's rectangle for the current
size, then the `par :grid(w, h)` block runs its body once per pixel. In the body
`par.x` and `par.y` are the pixel, `par.width` is the row stride, and the body
writes `gPixels[par.y * par.width + par.x]`. The values it reads from outside
the block (`minX`, `minY`, `stepPx`, `limit`) are scalars, copied to each work
item; the block may read them and may not write them, which is why the result
goes in the array. Everything is `float`, so the block has a GPU version on
every backend. A block that cannot run on a GPU still runs, on the CPU's
threads, so the program works either way.

The colours are an escape-time palette: a point in the set, still bounded after
`MAXIT` steps, is black, and one that escapes is tinted by how many steps it
took.

`render` then copies the pixels into a fresh buffer. The copy is needed because a
backend may cache what `drawPixels` is handed by its address, so the bytes it
reads must not change under it; a new buffer each time keeps the cache honest,
and the old one is freed here.

`drawRect` is the paint. It recomputes first when the region or the size
changed, then blits the buffer with
[`drawPixels`](/compiler/api/uxkit/uxgraphics/). While a drag is in progress it
also draws the rubber band, on top of the picture.

## The drag, keeping the window's shape

```c
    // ---- the mouse --------------------------------------------------------
    i32 localX(UXEvent* e)
    {
        return (i32)e.x - (i32)self.absoluteFrame().x;
    }
    i32 localY(UXEvent* e)
    {
        return (i32)e.y - (i32)self.absoluteFrame().y;
    }

    // The drag as a rectangle, grown to the window's shape and kept inside it.
    UXRect selection(void)
    {
        i32 vw = (i32)self.bounds().w;
        i32 vh = (i32)self.bounds().h;
        if (vw < (i32)1) { vw = (i32)1; }
        if (vh < (i32)1) { vh = (i32)1; }
        i32 xa = dx0 < dx1 ? dx0 : dx1;
        i32 ya = dy0 < dy1 ? dy0 : dy1;
        i32 rawW = dx0 < dx1 ? dx1 - dx0 : dx0 - dx1;
        i32 rawH = dy0 < dy1 ? dy1 - dy0 : dy0 - dy1;
        if (rawW < (i32)1) { rawW = (i32)1; }
        if (rawH < (i32)1) { rawH = (i32)1; }
        i32 w = rawW;
        i32 h = rawH;
        if (w * vh < h * vw) // too narrow: widen it to the window's shape
        {
            w = h * vw / vh;
        }
        else
        {
            h = w * vh / vw;
        }
        i32 nx = xa + rawW / 2 - w / 2; // centred on the drag
        i32 ny = ya + rawH / 2 - h / 2;
        if (nx + w > vw) { nx = vw - w; }
        if (ny + h > vh) { ny = vh - h; }
        if (nx < (i32)0) { nx = (i32)0; }
        if (ny < (i32)0) { ny = (i32)0; }
        return UXGeom.make((i16)nx, (i16)ny, (i16)w, (i16)h);
    }

    // The press, and the whole drag on a desktop: there the platform has no asynchronous drag, so the
    // view loops the driver's drag step until the button is released (the run loop is parked in it,
    // so the repaint happens here too).  A touch backend has no such loop; its mouseDragged and
    // mouseUp arrive instead.
    void mouseDown(UXEvent* e)
    {
        dx0 = self.localX(e);
        dy0 = self.localY(e);
        dx1 = dx0;
        dy1 = dy0;
        dragging = true;
        self.setNeedsDisplay();
        if (gApp != (UXApplication*)0)
        {
            gApp.displayIfNeeded(); // show the first point before the drag begins
        }
        if (gDriver != (UXViewDriver*)0 && gDriver.dragTrackingIsModal())
        {
            i32 x = (i32)e.x;
            i32 y = (i32)e.y;
            while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
                dx1 = x - (i32)self.absoluteFrame().x;
                dy1 = y - (i32)self.absoluteFrame().y;
                self.setNeedsDisplay();
                if (gApp != (UXApplication*)0)
                {
                    gApp.displayIfNeeded(); // make the band follow the pointer
                }
            }
            self.endDrag();
        }
    }
    void mouseDragged(UXEvent* e)
    {
        if (!dragging)
        {
            return;
        }
        dx1 = self.localX(e);
        dy1 = self.localY(e);
        self.setNeedsDisplay();
    }
    void mouseUp(UXEvent* e)
    {
        if (!dragging)
        {
            return;
        }
        dx1 = self.localX(e);
        dy1 = self.localY(e);
        self.endDrag();
    }
    // The button is up: a rectangle bigger than a few pixels is a zoom; anything smaller is a click.
    void endDrag(void)
    {
        dragging = false;
        UXRect r = self.selection();
        if ((i32)r.w > (i32)8 && (i32)r.h > (i32)8)
        {
            self.zoomTo(r);
            if (zoomed)
            {
                zoomed(self);
            }
            return;
        }
        self.setNeedsDisplay();
    }

    // Zoom to a rectangle of the view: map it back to the plane and recompute.
    void zoomTo(UXRect r)
    {
        i32 vw = (i32)self.bounds().w;
        i32 vh = (i32)self.bounds().h;
        if (vw < (i32)1) { vw = (i32)1; }
        if (vh < (i32)1) { vh = (i32)1; }
        float vspan = span * (float)vh / (float)vw;
        float minX = cx - span / 2.0f;
        float minY = cy - vspan / 2.0f;
        float fx = ((float)r.x + (float)r.w / 2.0f) / (float)vw;
        float fy = ((float)r.y + (float)r.h / 2.0f) / (float)vh;
        float fw = (float)r.w / (float)vw;
        cx = minX + fx * span;
        cy = minY + fy * vspan;
        span = fw * span;
        self.markDirty();
    }
}
```

The press and the drag are both in `mouseDown`. A desktop backend has no
asynchronous drag: the platform owns the run loop while the button is held, so
the view loops the driver's `trackDragStep` until the release, moving the
rectangle and repainting each step with `gApp.displayIfNeeded` because the run
loop is parked inside that loop. A touch backend has no such loop: there
`mouseDown` returns, the drag arrives as `mouseDragged`, and `mouseUp` ends it.
Both paths end at `endDrag`.

The points arrive in window coordinates, so each is made local to the view by
subtracting its `absoluteFrame`. `selection` turns the two corners into a
rectangle, grows the shorter side until the rectangle has the window's shape so
the zoom keeps the picture's proportions instead of stretching it, and nudges it
back inside the view.

`endDrag` treats a rectangle bigger than a few pixels as a zoom: `zoomTo` maps
it back to the plane and sets the new centre and span, and the view calls its
callback so the app can record the step. A smaller rectangle is a click, and
just clears the band.

## The history in the breadcrumb

```c
class App : Object<UXApplicationDelegate>
{
    UXWindow*     win;
    UXBreadcrumb* crumb;
    FractalView*  fractal;
    Array<Zoom>*  history;
    i32           current; // the step we are looking at
    float         fullSpan; // the first span, for the magnification label

    void init(void)
    {
        win = (UXWindow*)0;
        crumb = (UXBreadcrumb*)0;
        fractal = (FractalView*)0;
        history = new Array();
        current = (i32)0;
        fullSpan = 0.0f;
    }

    i32 applicationDidStart(UXApplication* app)
    {
        UXView* content = new UXView();
        win = new UXWindow();
        app.addWindow(win);
        win.open((u8*)"Mandelbrot", UXGeom.make(80, 80, 720, 520), content);

        crumb = new UXBreadcrumb();
        crumb.setSeparator((u8*)">");
        crumb.setAction(&self.onCrumb);
        content.addSubview(crumb, UXGeom.make(0, 0, 720, 24));
        crumb.setAutoresizeMask((i32)UX_ANCHOR_LEFT | (i32)UX_ANCHOR_TOP |
                                (i32)UX_ANCHOR_RIGHT | (i32)UX_FLEX_WIDTH);

        fractal = new FractalView();
        fractal.setOnZoomed(&self.onZoomed);
        content.addSubview(fractal, UXGeom.make(0, 24, 720, 496));
        fractal.setAutoresizeMask((i32)UX_ANCHOR_LEFT | (i32)UX_ANCHOR_TOP |
                                  (i32)UX_ANCHOR_RIGHT | (i32)UX_ANCHOR_BOTTOM |
                                  (i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);

        self.remember();
        win.tree.finalise();
        win.displayAll();
        return (i32)0;
    }

    // ---- the history ------------------------------------------------------
    // Add the view's current region as the newest step; a new zoom from a past
    // step drops whatever came after it.
    void remember(void)
    {
        while ((i32)history.count() > current + (i32)1)
        {
            history.removeLast();
        }
        Zoom* z = new Zoom();
        z.cx = fractal.cx;
        z.cy = fractal.cy;
        z.span = fractal.span;
        if (fullSpan <= 0.0f)
        {
            fullSpan = fractal.span;
        }
        history.add(z);
        current = (i32)history.count() - (i32)1;
        z.label = current == (i32)0 ? (u8*)"Home"
                                    : App.magLabel((i32)(fullSpan / z.span + 0.5f));
        self.rebuild();
    }
    void rebuild(void)
    {
        crumb.clear();
        for (i32 i = (i32)0; i < (i32)history.count(); i = i + (i32)1)
        {
            Zoom* z = (Zoom* ?)history.get((u32)i);
            crumb.addSegment(z.label, i);
        }
    }
    // "8x": how much closer than the whole set.  Hand-rolled rather than pulled
    // in for one label.
    static u8* magLabel(i32 mag)
    {
        if (mag < (i32)1) { mag = (i32)1; }
        u8* out = new u8[(u32)16];
        i32 d = (i32)0;
        i32 v = mag;
        while (v > (i32)0)
        {
            out[d] = (u8)('0' + v % (i32)10);
            v = v / (i32)10;
            d = d + (i32)1;
        }
        if (d == (i32)0)
        {
            out[d] = (u8)'0';
            d = (i32)1;
        }
        for (i32 k = (i32)0; k < d / 2; k = k + (i32)1)
        {
            u8 t = out[k];
            out[k] = out[d - (i32)1 - k];
            out[d - (i32)1 - k] = t;
        }
        out[d] = (u8)'x';
        out[d + (i32)1] = (u8)0;
        return out;
    }

    void onZoomed(FractalView* v)
    {
        self.remember();
    }
    // A crumb was clicked: go back to the step it names.
    void onCrumb(UXControl* sender)
    {
        i32 idx = crumb.selection();
        if (idx < (i32)0 || idx >= (i32)history.count())
        {
            return;
        }
        Zoom* z = (Zoom* ?)history.get((u32)idx);
        fractal.cx = z.cx;
        fractal.cy = z.cy;
        fractal.span = z.span;
        current = idx;
        fractal.markDirty();
    }
}

void main(void)
{
    UXApplication* app = new UXApplication();
    App* a = new App();
    app.setDelegate(a);
    app.run();
}
```

The app keeps the history. `remember` appends the view's current region after
dropping any steps past the current one, so a zoom from a past crumb branches
and the future is gone, and then rebuilds the breadcrumb. Each segment carries
its index as its tag, and its label is the magnification: `Home` for the first,
then `2x`, `8x`, and so on. `onCrumb` reads the clicked segment's tag and puts
the view back to that step.

`applicationDidStart` builds the window: a breadcrumb across the top and the
fractal view under it. The masks keep the breadcrumb at the top with a
stretching width and the view filling everything below, so resizing the window
resizes both.

## Build and run

The `doc-examples` gate builds it on macOS against the AppKit shim:

```
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
   -install_name "$PWD/libUXAppKit.dylib" frameworks/uxkit/libUXAppKit.m \
   -framework Cocoa -framework OpenGL -o libUXAppKit.dylib
xcc -A arm64 -I frameworks/uxkit website/site/examples/uxkit/mandelbrot.xc \
   -Xlinker "$PWD/libUXAppKit.dylib" -framework Cocoa -framework OpenGL \
   -o mandelbrot
```

Run it and drag a rectangle; the breadcrumb fills as you go. The GPU is used
where the platform has one (Metal on macOS, Vulkan on Linux and Android, the
NVIDIA driver or Vulkan on Windows, WebGPU in a browser). `XC_PAR_REPORT=1`
prints where each block ran, and `XC_PAR=cpu` keeps it on the CPU for
comparison.
