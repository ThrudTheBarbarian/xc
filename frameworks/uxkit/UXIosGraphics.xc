// UXIosGraphics.xc — the iOS/UIKit realization of UXGraphics (sibling of UXCocoaGraphics).
//
// The same primitives every drawRect calls, over the CGContext of the draw in
// flight (libUXIos.m's UXDrawView).  Bounds-relative coordinates in; the bound
// origin makes them absolute.  UIKit's coordinate space already grows y-down,
// so unlike the mac shim nothing needs flipping.
#import "UXGeometry.xc"
#import "UXGraphics.xc"

// The shim's drawing ops (act on the CGContext set by the draw in flight).
void ux_ios_circle(i32 cx, i32 cy, i32 r, i32 cr, i32 cg, i32 cb);
void ux_ios_fill(i32 x, i32 y, i32 w, i32 h, i32 r, i32 g, i32 b, i32 a);
void ux_ios_draw_pixels(u8* data, i32 w, i32 h, i32 format, i32 sx, i32 sy, i32 sw, i32 sh,
                        i32 dx, i32 dy, i32 dw, i32 dh, i32 alpha); // a bitmap region, scaled
void ux_ios_clear(i32 x, i32 y, i32 w, i32 h);
void ux_ios_text(u8* s, i32 x, i32 y, i32 r, i32 g, i32 b, i32 a, i32 size);
void ux_ios_text_font(u8* s, i32 x, i32 y, i32 r, i32 g, i32 b, u8* family, i32 size, i32 bold, i32 italic);
void ux_ios_text_weight(u8* s, i32 x, i32 y, u8* family, i32 size, i32 weight, i32 italic,
                        i32 r, i32 g, i32 b, i32 a);
void ux_ios_tri(i32 x0, i32 y0, i32 x1, i32 y1, i32 x2, i32 y2, i32 r, i32 g, i32 b);
void ux_ios_poly(i16* xy, i32 n, i32 r, i32 g, i32 b, i32 a);
void ux_ios_stroke_path(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                        i32* dash, i32 ndash, i32 phase, i32 r, i32 g, i32 b, i32 a);

class UXIosGraphics : Object<UXGraphics>
    {
    UXRect origin;

    void init(void)
        {
        origin = UXGeom.zero();
        }
    // per-paint, from the driver
    void bind(UXRect abs)
        {
        origin = abs;
        }
    bool hasThemeArt(void)
        {
        return false;
        }
    // CoreGraphics blends every fill and stroke source-over, so alpha composites here.
    bool blendsAlpha(void)
        {
        return true;
        }

    // A VDI pen index -> RGB (the shared toolkit palette, as every backend keeps it).
    void penRGB(i32 pen, i32* r, i32* g, i32* b)
        {
        // white
        if (pen == (i32)0)
            {
            r[0] = (i32)255;
            g[0] = (i32)255;
            b[0] = (i32)255;
            return;
            }
        // red
        if (pen == (i32)2)
            {
            r[0] = (i32)255;
            g[0] = (i32)0;
            b[0] = (i32)0;
            return;
            }
        // light grey
        if (pen == (i32)8)
            {
            r[0] = (i32)192;
            g[0] = (i32)192;
            b[0] = (i32)192;
            return;
            }
        // grey
        if (pen == (i32)9)
            {
            r[0] = (i32)128;
            g[0] = (i32)128;
            b[0] = (i32)128;
            return;
            }
        // selection blue
        if (pen == (i32)250)
            {
            r[0] = (i32)179;
            g[0] = (i32)215;
            b[0] = (i32)255;
            return;
            }
        r[0] = (i32)0;
        g[0] = (i32)0;
        b[0] = (i32)0; // black
        }

    void fillRect(UXRect r, i32 pen)
        {
        i32 cr = (i32)0;
        i32 cg = (i32)0;
        i32 cb = (i32)0;
        self.penRGB(pen, &cr, &cg, &cb);
        ux_ios_fill((i32)(origin.x + r.x), (i32)(origin.y + r.y), (i32)r.w, (i32)r.h, cr, cg, cb, (i32)255);
        }
    void fillRectRGB(UXRect r, i32 red, i32 green, i32 blue)
        {
        self.fillRectRGBA(r, red, green, blue, (i32)255);
        }
    void fillRectRGBA(UXRect r, i32 red, i32 green, i32 blue, i32 alpha)
        {
        ux_ios_fill((i32)(origin.x + r.x), (i32)(origin.y + r.y), (i32)r.w, (i32)r.h, red, green, blue, alpha);
        }
    // A bitmap region, scaled, with alpha: a CGImage cached by the bitmap's address (as on AppKit).
    void drawPixels(u8* data, i32 w, i32 h, i32 format, UXRect src, UXRect dst, i32 alpha)
        {
        ux_ios_draw_pixels(data, w, h, format, (i32)src.x, (i32)src.y, (i32)src.w, (i32)src.h,
                           (i32)(origin.x + dst.x), (i32)(origin.y + dst.y), (i32)dst.w, (i32)dst.h, alpha);
        }
    // CGContextClearRect: the rect comes back transparent, whatever was under it.
    void clearRect(UXRect r)
        {
        ux_ios_clear((i32)(origin.x + r.x), (i32)(origin.y + r.y), (i32)r.w, (i32)r.h);
        }
    // no 9-slice yet
    void drawTheme(u8* slice, UXRect r)
        {
        self.fillRect(r, (i32)8);
        }

    void drawText(u8* s, i16 x, i16 y, i32 pen, i32 size)
        {
        i32 cr = (i32)0;
        i32 cg = (i32)0;
        i32 cb = (i32)0;
        self.penRGB(pen, &cr, &cg, &cb);
        ux_ios_text(s, (i32)(origin.x + x), (i32)(origin.y + y), cr, cg, cb, (i32)255, size);
        }
    void drawTextRGBA(u8* s, i16 x, i16 y, i32 red, i32 green, i32 blue, i32 alpha, i32 size)
        {
        ux_ios_text(s, (i32)(origin.x + x), (i32)(origin.y + y), red, green, blue, alpha, size);
        }
    void drawTextFont(u8* s, i16 x, i16 y, i32 pen, u8* family, i32 size, bool bold, bool italic)
        {
        i32 cr = (i32)0;
        i32 cg = (i32)0;
        i32 cb = (i32)0;
        self.penRGB(pen, &cr, &cg, &cb);
        ux_ios_text_font(s, (i32)(origin.x + x), (i32)(origin.y + y), cr, cg, cb,
                         family, size, bold ? (i32)1 : (i32)0, italic ? (i32)1 : (i32)0);
        }
    void drawTextFontRGBA(u8* s, i16 x, i16 y, u8* family, i32 size, i32 weight, bool italic,
                          i32 red, i32 green, i32 blue, i32 alpha)
        {
        ux_ios_text_weight(s, (i32)(origin.x + x), (i32)(origin.y + y), family, size, weight,
                           italic ? (i32)1 : (i32)0, red, green, blue, alpha);
        }

    void fillTriangle(i16 x0, i16 y0, i16 x1, i16 y1, i16 x2, i16 y2, i32 pen)
        {
        i32 cr = (i32)0;
        i32 cg = (i32)0;
        i32 cb = (i32)0;
        self.penRGB(pen, &cr, &cg, &cb);
        ux_ios_tri((i32)(origin.x + x0), (i32)(origin.y + y0),
                   (i32)(origin.x + x1), (i32)(origin.y + y1),
                   (i32)(origin.x + x2), (i32)(origin.y + y2), cr, cg, cb);
        }
    void fillPolygon(i16* xy, i32 n, i32 pen)
        {
        i32 cr = (i32)0;
        i32 cg = (i32)0;
        i32 cb = (i32)0;
        self.penRGB(pen, &cr, &cg, &cb);
        self.polyRGBA(xy, n, cr, cg, cb, (i32)255);
        }
    void fillPolygonRGB(i16* xy, i32 n, i32 red, i32 green, i32 blue)
        {
        self.polyRGBA(xy, n, red, green, blue, (i32)255);
        }
    void fillPolygonRGBA(i16* xy, i32 n, i32 red, i32 green, i32 blue, i32 alpha)
        {
        self.polyRGBA(xy, n, red, green, blue, alpha);
        }
    void polyRGBA(i16* xy, i32 n, i32 r, i32 g, i32 b, i32 a)
        {
        if (n < (i32)3)
            {
            return;
            }
        // the shared v_fillarea ceiling
        if (n > (i32)128)
            {
            n = (i32)128;
            }
        i16 pts[256];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            pts[i * (i32)2] = (i16)(origin.x + xy[i * (i32)2]);
            pts[i * (i32)2 + (i32)1] = (i16)(origin.y + xy[i * (i32)2 + (i32)1]);
            }
        ux_ios_poly(&pts[(i32)0], n, r, g, b, a);
        }

    // CoreGraphics strokes real cubics with joins and caps, same as the mac.
    bool strokesNatively(void)
        {
        return true;
        }
    // ...and CGContextSetLineDash takes a run and a phase, the same pair NSBezierPath takes.
    bool dashesNatively(void)
        {
        return true;
        }
    void strokeNative(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                      i32* dash, i32 ndash, i32 phase, i32 pen)
        {
        i32 cr = (i32)0;
        i32 cg = (i32)0;
        i32 cb = (i32)0;
        self.penRGB(pen, &cr, &cg, &cb);
        self.strokeNativeRGBA(ops, n, width, startCap, endCap, join, dash, ndash, phase,
                              cr, cg, cb, (i32)255);
        }
    void strokeNativeRGB(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                         i32* dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue)
        {
        self.strokeNativeRGBA(ops, n, width, startCap, endCap, join, dash, ndash, phase,
                              red, green, blue, (i32)255);
        }
    void strokeNativeRGBA(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                          i32* dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue, i32 alpha)
        {
        self.offsetOps(ops, n, (i32)origin.x, (i32)origin.y);
        ux_ios_stroke_path(ops, n, width, startCap, endCap, join, dash, ndash, phase,
                           red, green, blue, alpha);
        self.offsetOps(ops, n, -(i32)origin.x, -(i32)origin.y); // the caller's run stays as it was
        }
    void offsetOps(i32* ops, i32 n, i32 dx, i32 dy)
        {
        i32 i = (i32)0;
        while (i < n)
            {
            i32 op = ops[i];
            i = i + (i32)1;
            i32 pairs = op == (i32)UXSTROKE_CURVE ? (i32)3 : (op == (i32)UXSTROKE_CLOSE ? (i32)0 : (i32)1);
            for (i32 k = (i32)0; k < pairs && i + (i32)1 < n + (i32)1; k = k + (i32)1)
                {
                ops[i] = ops[i] + dx;
                ops[i + (i32)1] = ops[i + (i32)1] + dy;
                i = i + (i32)2;
                }
            }
        }

    void fillCircle(i16 cx, i16 cy, i16 r, i32 pen)
        {
        i32 cr = (i32)0;
        i32 cg = (i32)0;
        i32 cb = (i32)0;
        self.penRGB(pen, &cr, &cg, &cb);
        ux_ios_circle((i32)(origin.x + cx), (i32)(origin.y + cy), (i32)r, cr, cg, cb);
        }
    void drawLine(i16 x0, i16 y0, i16 x1, i16 y1, i32 pen)
        {
        self.fillTriangle(x0, y0, x1, y1, x1, (i16)(y1 + (i16)2), pen);
        }
    }
