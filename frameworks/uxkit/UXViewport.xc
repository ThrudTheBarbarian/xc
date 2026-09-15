// UXViewport.xc — a pan + zoom coordinate mapper for a scrollable/zoomable canvas.
//
// Maps document coordinates to screen and back through an integer zoom (percent; 100 = 1:1) and a pan
// offset.  zoomAtPoint keeps the document point under a screen location fixed while zooming — the
// "zoom toward the cursor" every canvas wants.  Integer maths, so it is exact and testable; a drawing
// view multiplies its coordinates through this instead of hand-rolling scroll+scale each time.
#import "Array.xc"
#import "UXGeometry.xc"

class UXViewport
    {
    i32 zoom; // percent (100 = 1:1)
    i32 panX; // screen offset of document origin
    i32 panY;
    void init(void)
        {
        zoom = (i32)100;
        panX = (i32)0;
        panY = (i32)0;
        }

    // doc -> screen
    i32 docToScreenX(i32 dx)
        {
        return dx * zoom / (i32)100 + panX;
        }
    i32 docToScreenY(i32 dy)
        {
        return dy * zoom / (i32)100 + panY;
        }
    // screen -> doc (inverse)
    i32 screenToDocX(i32 sx)
        {
        return zoom != (i32)0 ? (sx - panX) * (i32)100 / zoom : (i32)0;
        }
    i32 screenToDocY(i32 sy)
        {
        return zoom != (i32)0 ? (sy - panY) * (i32)100 / zoom : (i32)0;
        }

    void setZoom(i32 pct)
        {
        if (pct < (i32)1)
            {
            pct = (i32)1;
            }
        zoom = pct;
        }
    void panTo(i32 x, i32 y)
        {
        panX = x;
        panY = y;
        }
    void panBy(i32 dx, i32 dy)
        {
        panX = panX + dx;
        panY = panY + dy;
        }

    // Change the zoom while keeping the document point currently under (screenX, screenY) in place.
    void zoomAtPoint(i32 pct, i32 screenX, i32 screenY)
        {
        i32 docX = self.screenToDocX(screenX);
        i32 docY = self.screenToDocY(screenY);
        self.setZoom(pct);
        panX = screenX - docX * zoom / (i32)100; // solve docToScreen(docX) == screenX
        panY = screenY - docY * zoom / (i32)100;
        }

    // The document rectangle currently visible in a screen viewport of (w, h).
    UXRect visibleDocRect(i32 w, i32 h)
        {
        i32 dx = self.screenToDocX((i32)0);
        i32 dy = self.screenToDocY((i32)0);
        i32 dw = self.screenToDocX(w) - dx;
        i32 dh = self.screenToDocY(h) - dy;
        return UXGeom.make((i16)dx, (i16)dy, (i16)dw, (i16)dh);
        }
    }
