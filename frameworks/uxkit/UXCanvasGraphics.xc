// UXCanvasGraphics.xc — the Canvas2D realization of UXGraphics (doc/UXKit-WEB-BACKEND.md §2).
//
// The sibling of UXGdiGraphics: the same primitives every drawRect calls, over the
// host canvas imports instead of a device context.  Bounds-relative coordinates in;
// the bound origin makes them absolute, exactly as on the other three backends.
// The pen→colour table is here, xtc-side, so the JS surface only ever sees r,g,b.
#import "UXWeb.h.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"

class UXCanvasGraphics : Object<UXGraphics>
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
        return true;
        }

    // The VDI pen indices the toolkit draws with, as RGB — the same table the
    // GDI driver keeps (penColor), split per channel for the import signature.
    i32 penR(i32 pen)
        {
        // white
        if (pen == (i32)0)
            {
            return (i32)255;
            }
        // red
        if (pen == (i32)2)
            {
            return (i32)255;
            }
        // light grey (selection)
        if (pen == (i32)8)
            {
            return (i32)192;
            }
        // grey
        if (pen == (i32)9)
            {
            return (i32)128;
            }
        // selection blue
        if (pen == (i32)250)
            {
            return (i32)179;
            }
        return (i32)0; // black (pen 1 and default)
        }
    i32 penG(i32 pen)
        {
        if (pen == (i32)0)
            {
            return (i32)255;
            }
        if (pen == (i32)8)
            {
            return (i32)192;
            }
        if (pen == (i32)9)
            {
            return (i32)128;
            }
        if (pen == (i32)250)
            {
            return (i32)215;
            }
        return (i32)0;
        }
    i32 penB(i32 pen)
        {
        if (pen == (i32)0)
            {
            return (i32)255;
            }
        if (pen == (i32)8)
            {
            return (i32)192;
            }
        if (pen == (i32)9)
            {
            return (i32)128;
            }
        if (pen == (i32)250)
            {
            return (i32)255;
            }
        return (i32)0;
        }

    void fillRect(UXRect r, i32 pen)
        {
        ux_fill_rect((i32)(origin.x + r.x), (i32)(origin.y + r.y), (i32)r.w, (i32)r.h,
                     self.penR(pen), self.penG(pen), self.penB(pen));
        }
    void fillRectRGB(UXRect r, i32 red, i32 green, i32 blue)
        {
        ux_fill_rect((i32)(origin.x + r.x), (i32)(origin.y + r.y), (i32)r.w, (i32)r.h,
                     red, green, blue);
        }
    void drawTheme(u8* slice, UXRect r)
        {
        ux_draw_theme(slice, (i32)(origin.x + r.x), (i32)(origin.y + r.y), (i32)r.w, (i32)r.h);
        }
    void drawText(u8* s, i16 x, i16 y, i32 pen, i32 size)
        {
        ux_draw_text(s, (i32)(origin.x + x), (i32)(origin.y + y), (u8*)"", size, (i32)0, (i32)0,
                     self.penR(pen), self.penG(pen), self.penB(pen));
        }
    void drawTextFont(u8* s, i16 x, i16 y, i32 pen, u8* family, i32 size, bool bold, bool italic)
        {
        ux_draw_text(s, (i32)(origin.x + x), (i32)(origin.y + y), family, size,
                     bold ? (i32)1 : (i32)0, italic ? (i32)1 : (i32)0,
                     self.penR(pen), self.penG(pen), self.penB(pen));
        }
    void fillTriangle(i16 x0, i16 y0, i16 x1, i16 y1, i16 x2, i16 y2, i32 pen)
        {
        i16 xy[6];
        xy[0] = x0;
        xy[1] = y0;
        xy[2] = x1;
        xy[3] = y1;
        xy[4] = x2;
        xy[5] = y2;
        self.fillPolygon(&xy[0], (i32)3, pen);
        }
    void fillCircle(i16 cx, i16 cy, i16 r, i32 pen)
        {
        ux_fill_circle((i32)(origin.x + cx), (i32)(origin.y + cy), (i32)r,
                       self.penR(pen), self.penG(pen), self.penB(pen));
        }
    void drawLine(i16 x0, i16 y0, i16 x1, i16 y1, i32 pen)
        {
        ux_draw_line((i32)(origin.x + x0), (i32)(origin.y + y0),
                     (i32)(origin.x + x1), (i32)(origin.y + y1),
                     self.penR(pen), self.penG(pen), self.penB(pen));
        }
    // The polygon points are shifted into absolute coordinates IN PLACE on a copy —
    // the import reads i16 pairs straight out of linear memory, one crossing per shape.
    void fillPolygon(i16* xy, i32 n, i32 pen)
        {
        self.polyRGB(xy, n, self.penR(pen), self.penG(pen), self.penB(pen));
        }
    void fillPolygonRGB(i16* xy, i32 n, i32 red, i32 green, i32 blue)
        {
        self.polyRGB(xy, n, red, green, blue);
        }
    void polyRGB(i16* xy, i32 n, i32 red, i32 green, i32 blue)
        {
        if (n < (i32)3)
            {
            return;
            }
        // the v_fillarea ceiling, kept cross-backend
        if (n > (i32)128)
            {
            n = (i32)128;
            }
        i16 abs[256];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            abs[i * (i32)2] = (i16)(origin.x + xy[i * (i32)2]);
            abs[i * (i32)2 + (i32)1] = (i16)(origin.y + xy[i * (i32)2 + (i32)1]);
            }
        ux_fill_poly(&abs[0], n, red, green, blue);
        }

    // Canvas2D strokes real cubics with width, round joins and caps — the same
    // sub-pixel silhouette AppKit and GDI buy, for one import.  The op run is
    // rebased to absolute coordinates on a copy and walked JS-side into a Path2D.
    bool strokesNatively(void)
        {
        return true;
        }
    void strokeNative(i32* ops, i32 n, i32 width, i32 startCap, i32 endCap, i32 pen)
        {
        self.strokeOps(ops, n, width, startCap, endCap,
                       self.penR(pen), self.penG(pen), self.penB(pen));
        }
    void strokeNativeRGB(i32* ops, i32 n, i32 width, i32 startCap, i32 endCap,
                         i32 red, i32 green, i32 blue)
        {
        self.strokeOps(ops, n, width, startCap, endCap, red, green, blue);
        }
    void strokeOps(i32* ops, i32 n, i32 width, i32 startCap, i32 endCap,
                   i32 red, i32 green, i32 blue)
        {
        if (n <= (i32)0 || width <= (i32)0 || n > (i32)512)
            {
            return;
            }
        i32 abs[512];
        i32 ox = (i32)origin.x;
        i32 oy = (i32)origin.y;
        i32 i = (i32)0;
        while (i < n)
            {
            i32 op = ops[i];
            abs[i] = op;
            i = i + (i32)1;
            i32 coords = (i32)0;
            if (op == (i32)UXSTROKE_MOVE || op == (i32)UXSTROKE_LINE)
                {
                coords = (i32)2;
                }
            else if (op == (i32)UXSTROKE_CURVE)
                {
                coords = (i32)6;
                }
            else if (op != (i32)UXSTROKE_CLOSE)
                {
                break;
                }
            if (i + coords > n)
                {
                break;
                }
            for (i32 k = (i32)0; k < coords; k = k + (i32)2)
                {
                abs[i + k] = ox + ops[i + k];
                abs[i + k + (i32)1] = oy + ops[i + k + (i32)1];
                }
            i = i + coords;
            }
        // One cap for the whole path, the rounder end wins — the GDI rule, kept for parity.
        i32 cap = startCap > endCap ? startCap : endCap;
        ux_stroke_ops(&abs[0], i, width, cap, red, green, blue);
        }
    }
