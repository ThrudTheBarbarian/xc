// mandelbrot.xc — a Mandelbrot set you can zoom into with the mouse, computed
// on the GPU and drawn by a custom widget.
//
// The picture is a plain UXView that draws itself from a pixel buffer a `par`
// block fills — on the GPU where there is one, on the CPU's threads otherwise.
// Drag a rectangle and the view zooms to it, keeping the window's shape; the
// breadcrumb above remembers every step, so you can click back to one.
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

#define MAXW 4096 // the largest picture we compute; room for a 4K window.  The
#define MAXH 2304 // buffer is fixed, so a window bigger than it is the one size
#define MAXIT 256 // that scales rather than recomputes.  Iterations per pixel.

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
        label = "";
        }
    }

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
        imgW = 0;
        imgH = 0;
        dirty = true;
        dragging = false;
        dx0 = 0;
        dy0 = 0;
        dx1 = 0;
        dy1 = 0;
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

    // ---- the pixels -------------------------------------------------------
    // Fill the buffer for the current region at the current size.  A `par` grid
    // runs the body once per pixel; the compiler turns it into a GPU kernel.
    void render(void)
        {
        i32 w = self.bounds().w;
        i32 h = self.bounds().h;
        if (w > MAXW) { w = MAXW; }
        if (h > MAXH) { h = MAXH; }
        if (w < 1 || h < 1)
            {
            return;
            }
        float vspan = span * (float)h / (float)w; // the plane's height for this window
        float minX = cx - span / 2.0f;
        float minY = cy - vspan / 2.0f;
        float stepPx = span / (float)w; // one pixel, in the plane
        float limit = 4.0f;
        par mandelbrot :grid(w, h)
            {
            float cr = minX + ((float)par.x + 0.5f) * stepPx;
            float ci = minY + ((float)par.y + 0.5f) * stepPx;
            float zx = 0.0f;
            float zy = 0.0f;
            i32   it = 0;
            while (it < MAXIT)
                {
                float zx2 = zx * zx;
                float zy2 = zy * zy;
                if (zx2 + zy2 > limit)
                    {
                    break; // escaped
                    }
                zy = 2.0f * zx * zy + ci;
                zx = zx2 - zy2 + cr;
                it = it + 1;
                }
            u32 c;
            if (it >= MAXIT)
                {
                c = 0xFF000000; // in the set: black
                }
            else
                {
                u32 t = it;
                c = 0xFF000000 | (((t * 9) & 0xFF) << 16)
                               | (((t * 5) & 0xFF) << 8)
                               |  ((t * 3) & 0xFF);
                }
            gPixels[par.y * par.width + par.x] = c;
            }
        // Copy into a fresh buffer.  drawPixels may cache what it is handed by
        // its address, so the bytes it reads must not change under it.
        if (shown != (u32*)0)
            {
            free((pointer)shown);
            }
        u32 n = (w * h);
        shown = (u32*)malloc(n * 4);
        for (u32 k = 0; k < n; k = k + 1)
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
        if (b.w != imgW || b.h != imgH || dirty)
            {
            self.render();
            }
        if (shown != (u32*)0)
            {
            g.drawPixels((u8*)shown, imgW, imgH, UXPIX_ARGB32,
                         UXGeom.make(0, 0, imgW, imgH), b, 255);
            }
        if (dragging)
            {
            self.outline(g, self.selection());
            }
        }
    // A hollow yellow rectangle, four thin bars, drawn over the picture while a drag is in progress.
    void outline(UXGraphics* g, UXRect r)
        {
        i16 t = 2; // the bar's thickness
        i32 yb = r.y + r.h - t;
        i32 xr = r.x + r.w - t;
        g.fillRectRGB(UXGeom.make(r.x, r.y, r.w, t), 255, 255, 0);
        g.fillRectRGB(UXGeom.make(r.x, yb, r.w, t), 255, 255, 0);
        g.fillRectRGB(UXGeom.make(r.x, r.y, t, r.h), 255, 255, 0);
        g.fillRectRGB(UXGeom.make(xr, r.y, t, r.h), 255, 255, 0);
        }

    // ---- the mouse --------------------------------------------------------
    i32 localX(UXEvent* e)
        {
        return e.x - self.absoluteFrame().x;
        }
    i32 localY(UXEvent* e)
        {
        return e.y - self.absoluteFrame().y;
        }

    // The drag as a rectangle, grown to the window's shape and kept inside it.
    UXRect selection(void)
        {
        i32 vw = self.bounds().w;
        i32 vh = self.bounds().h;
        if (vw < 1) { vw = 1; }
        if (vh < 1) { vh = 1; }
        i32 xa = dx0 < dx1 ? dx0 : dx1;
        i32 ya = dy0 < dy1 ? dy0 : dy1;
        i32 rawW = dx0 < dx1 ? dx1 - dx0 : dx0 - dx1;
        i32 rawH = dy0 < dy1 ? dy1 - dy0 : dy0 - dy1;
        if (rawW < 1) { rawW = 1; }
        if (rawH < 1) { rawH = 1; }
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
        if (nx < 0) { nx = 0; }
        if (ny < 0) { ny = 0; }
        return UXGeom.make(nx, ny, w, h);
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
            i32 x = e.x;
            i32 y = e.y;
            while (gDriver.trackDragStep(&x, &y) != 0)
                {
                dx1 = x - self.absoluteFrame().x;
                dy1 = y - self.absoluteFrame().y;
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
        if (r.w > 8 && r.h > 8)
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
        i32 vw = self.bounds().w;
        i32 vh = self.bounds().h;
        if (vw < 1) { vw = 1; }
        if (vh < 1) { vh = 1; }
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
        current = 0;
        fullSpan = 0.0f;
        }

    i32 applicationDidStart(UXApplication* app)
        {
        UXView* content = new UXView();
        win = new UXWindow();
        app.addWindow(win);
        win.open("Mandelbrot", UXGeom.make(80, 80, 720, 520), content);

        crumb = new UXBreadcrumb();
        crumb.setSeparator(">");
        crumb.setAction(&self.onCrumb);
        content.addSubview(crumb, UXGeom.make(0, 0, 720, 24));
        crumb.setAutoresizeMask(UX_ANCHOR_LEFT | UX_ANCHOR_TOP |
                                UX_ANCHOR_RIGHT | UX_FLEX_WIDTH);

        fractal = new FractalView();
        fractal.setOnZoomed(&self.onZoomed);
        content.addSubview(fractal, UXGeom.make(0, 24, 720, 496));
        fractal.setAutoresizeMask(UX_ANCHOR_LEFT | UX_ANCHOR_TOP |
                                  UX_ANCHOR_RIGHT | UX_ANCHOR_BOTTOM |
                                  UX_FLEX_WIDTH | UX_FLEX_HEIGHT);

        self.remember();
        win.tree.finalise();
        win.displayAll();
        return 0;
        }

    // ---- the history ------------------------------------------------------
    // Add the view's current region as the newest step; a new zoom from a past
    // step drops whatever came after it.
    void remember(void)
        {
        while (history.count() > current + 1)
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
        current = history.count() - 1;
        z.label = current == 0 ? "Home"
                                    : App.magLabel((fullSpan / z.span + 0.5f));
        self.rebuild();
        }
    void rebuild(void)
        {
        crumb.clear();
        for (i32 i = 0; i < history.count(); i = i + 1)
            {
            Zoom* z = (Zoom* ?)history.get(i);
            crumb.addSegment(z.label, i);
            }
        }
    // "8x": how much closer than the whole set.  Hand-rolled rather than pulled
    // in for one label.
    static u8* magLabel(i32 mag)
        {
        if (mag < 1) { mag = 1; }
        u8* out = new u8[16];
        i32 d = 0;
        i32 v = mag;
        while (v > 0)
            {
            out[d] = ('0' + v % 10);
            v = v / 10;
            d = d + 1;
            }
        if (d == 0)
            {
            out[d] = '0';
            d = 1;
            }
        for (i32 k = 0; k < d / 2; k = k + 1)
            {
            u8 t = out[k];
            out[k] = out[d - 1 - k];
            out[d - 1 - k] = t;
            }
        out[d] = 'x';
        out[d + 1] = 0;
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
        if (idx < 0 || idx >= history.count())
            {
            return;
            }
        Zoom* z = (Zoom* ?)history.get(idx);
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
