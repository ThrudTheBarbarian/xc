// UXGdiGraphics.xc — the Win32/GDI realization of UXGraphics (sibling of UXGemGraphics).
//
// The same four primitives every drawRect calls, over a device context instead of the VDI.
// Bounds-relative coordinates in; the bound origin makes them absolute, exactly as on GEM.
#import "UXWin32.h.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"

// drawPixels' GDI calls, resolved from gdi32 by name: neither is in the toolchain's import map.
pointer gGdiCreateDIBSection;
pointer gGdiAlphaBlend;
i32 gGdiPixTried;
typedef pointer GdiCreateDIBSectionFn(pointer hdc, pointer bmi, u32 usage, pointer* bits, pointer sec, u32 off);
typedef i32 GdiAlphaBlendFn(pointer d, i32 xd, i32 yd, i32 wd, i32 hd, pointer s, i32 xs, i32 ys, i32 ws, i32 hs,
                            u32 blend);
struct GdiBmiHeader
    {
    u32 biSize;
    i32 biWidth;
    i32 biHeight;
    u16 biPlanes;
    u16 biBitCount;
    u32 biCompression;
    u32 biSizeImage;
    i32 biXPelsPerMeter;
    i32 biYPelsPerMeter;
    u32 biClrUsed;
    u32 biClrImportant;
    }

class UXGdiGraphics : Object<UXGraphics>
    {
    pointer hdc;
    UXRect origin;

    void init(void)
        {
        hdc = (pointer)0;
        origin = UXGeom.zero();
        }

    // per-paint, from the driver
    void bind(pointer dc, UXRect abs)
        {
        hdc = dc;
        origin = abs;
        }
    bool hasThemeArt(void)
        {
        return false;
        }

    // A VDI pen index mapped to a GDI COLORREF (0x00BBGGRR).  A small table is enough for the
    // toolkit's palette; a full driver would honour the theme's colours.
    u32 penColor(i32 pen)
        {
        // white (VDI pen 0)  [COLORREF is 0x00BBGGRR]
        if (pen == (i32)0)
            {
            return (u32)$00FFFFFF;
            }
        // red
        if (pen == (i32)2)
            {
            return (u32)$000000FF;
            }
        // light grey (selection)
        if (pen == (i32)8)
            {
            return (u32)$00C0C0C0;
            }
        // grey
        if (pen == (i32)9)
            {
            return (u32)$00808080;
            }
        // selection blue (0x00BBGGRR = 179,215,255; was black!)
        if (pen == (i32)250)
            {
            return (u32)$00FFD7B3;
            }
        return (u32)$00000000; // black (pen 1 and default)
        }

    void fillRect(UXRect r, i32 pen)
        {
        RECT rc;
        rc.left = (i32)(origin.x + r.x);
        rc.top = (i32)(origin.y + r.y);
        rc.right = (i32)(origin.x + r.x + r.w);
        rc.bottom = (i32)(origin.y + r.y + r.h);
        pointer br = CreateSolidBrush(self.penColor(pen));
        FillRect(hdc, (pointer)&rc, br);
        DeleteObject(br);
        }

    void fillRectRGB(UXRect r, i32 red, i32 green, i32 blue)
        {
        RECT rc;
        rc.left = (i32)(origin.x + r.x);
        rc.top = (i32)(origin.y + r.y);
        rc.right = (i32)(origin.x + r.x + r.w);
        rc.bottom = (i32)(origin.y + r.y + r.h);
        pointer br = CreateSolidBrush((u32)red | ((u32)green << (u32)8) | ((u32)blue << (u32)16)); // COLORREF 0x00BBGGRR
        FillRect(hdc, (pointer)&rc, br);
        DeleteObject(br);
        }
    // GDI fills and strokes opaque: a solid brush has no alpha, and per-shape blending would need an
    // offscreen DIB per primitive.  blendsAlpha() answers false; the colour is drawn opaque.
    void fillRectRGBA(UXRect r, i32 red, i32 green, i32 blue, i32 alpha)
        {
        self.fillRectRGB(r, red, green, blue);
        }
    // A bitmap region: the region is converted to PREMULTIPLIED BGRA in a DIB section (what
    // AlphaBlend reads), then AlphaBlend scales it into the destination with its per-pixel alpha and
    // the overall `alpha` as the constant.  Converted per call, region only: an icon is a few hundred
    // pixels, and the whole atlas is never touched.
    void drawPixels(u8* data, i32 w, i32 h, i32 format, UXRect src, UXRect dst, i32 alpha)
        {
        if (hdc == (pointer)0 || data == (u8*)0 || alpha <= (i32)0 || dst.w <= (i16)0 || dst.h <= (i16)0)
            {
            return;
            }
        if (gGdiPixTried == (i32)0)
            {
            gGdiPixTried = (i32)1;
            pointer gdi = LoadLibraryA((pointer)"gdi32.dll");
            if (gdi != (pointer)0)
                {
                gGdiCreateDIBSection = GetProcAddress(gdi, (u8*)"CreateDIBSection");
                gGdiAlphaBlend = GetProcAddress(gdi, (u8*)"GdiAlphaBlend");
                }
            }
        if (gGdiCreateDIBSection == (pointer)0 || gGdiAlphaBlend == (pointer)0)
            {
            return;
            }
        i32 sx = (i32)src.x < (i32)0 ? (i32)0 : (i32)src.x;
        i32 sy = (i32)src.y < (i32)0 ? (i32)0 : (i32)src.y;
        i32 sw = (i32)src.w;
        i32 sh = (i32)src.h;
        if (sx + sw > w) { sw = w - sx; }
        if (sy + sh > h) { sh = h - sy; }
        if (sw <= (i32)0 || sh <= (i32)0)
            {
            return;
            }
        GdiBmiHeader bmi;
        bmi.biSize = (u32)40;
        bmi.biWidth = sw;
        bmi.biHeight = (i32)0 - sh; // negative: top-down, the order the bitmap is in
        bmi.biPlanes = (u16)1;
        bmi.biBitCount = (u16)32;
        bmi.biCompression = (u32)0;
        bmi.biSizeImage = (u32)0;
        bmi.biXPelsPerMeter = (i32)0;
        bmi.biYPelsPerMeter = (i32)0;
        bmi.biClrUsed = (u32)0;
        bmi.biClrImportant = (u32)0;
        pointer bits = (pointer)0;
        GdiCreateDIBSectionFn* mk = (GdiCreateDIBSectionFn*)gGdiCreateDIBSection;
        pointer dib = mk(hdc, (pointer)&bmi, (u32)0, &bits, (pointer)0, (u32)0);
        if (dib == (pointer)0 || bits == (pointer)0)
            {
            return;
            }
        u8* out = (u8*)bits;
        for (i32 y = (i32)0; y < sh; y = y + (i32)1)
            {
            for (i32 x = (i32)0; x < sw; x = x + (i32)1)
                {
                u8* q = data + ((sy + y) * w + (sx + x)) * (i32)4;
                i32 r = (i32)q[0];
                i32 g = (i32)q[1];
                i32 b = (i32)q[2];
                i32 a = (i32)q[3];
                if (format == (i32)UXPIX_ARGB32) // 0xAARRGGBB words, little-endian: B,G,R,A in memory
                    {
                    r = (i32)q[2];
                    b = (i32)q[0];
                    }
                u8* o = out + (y * sw + x) * (i32)4;
                o[0] = (u8)((b * a + (i32)127) / (i32)255);
                o[1] = (u8)((g * a + (i32)127) / (i32)255);
                o[2] = (u8)((r * a + (i32)127) / (i32)255);
                o[3] = (u8)a;
                }
            }
        pointer mem = CreateCompatibleDC(hdc);
        pointer old = SelectObject(mem, dib);
        // BLENDFUNCTION by value: AC_SRC_OVER, 0 flags, the constant alpha, AC_SRC_ALPHA.
        u32 blend = ((u32)(alpha > (i32)255 ? (i32)255 : alpha) << (u32)16) | ((u32)1 << (u32)24);
        GdiAlphaBlendFn* ab = (GdiAlphaBlendFn*)gGdiAlphaBlend;
        ab(hdc, (i32)(origin.x + dst.x), (i32)(origin.y + dst.y), (i32)dst.w, (i32)dst.h, mem, (i32)0, (i32)0, sw, sh, blend);
        SelectObject(mem, old);
        DeleteObject(dib);
        DeleteDC(mem);
        }
    // No alpha in a solid brush, so "empty" is the window background: WHITE_BRUSH, the same white the
    // toolkit's own backgrounds use.  See the protocol note; a see-through layer takes the blendsAlpha
    // path instead.
    void clearRect(UXRect r)
        {
        RECT rc;
        rc.left = (i32)(origin.x + r.x);
        rc.top = (i32)(origin.y + r.y);
        rc.right = (i32)(origin.x + r.x + r.w);
        rc.bottom = (i32)(origin.y + r.y + r.h);
        FillRect(hdc, (pointer)&rc, GetStockObject((i32)WHITE_BRUSH));
        }

    // No native 9-slice in the minimal driver — a filled box stands in for themed widget art.
    void drawTheme(u8* slice, UXRect r)
        {
        self.fillRect(r, (i32)8);
        }

    void drawText(u8* s, i16 x, i16 y, i32 pen, i32 size)
        {
        self.textCore(s, x, y, self.penColor(pen), size);
        }
    void drawTextRGBA(u8* s, i16 x, i16 y, i32 red, i32 green, i32 blue, i32 alpha, i32 size)
        {
        self.textCore(s, x, y, (u32)red | ((u32)green << (u32)8) | ((u32)blue << (u32)16), size);
        }
    void textCore(u8* s, i16 x, i16 y, u32 colorref, i32 size)
        {
        SetBkMode(hdc, (i32)TRANSPARENT);
        SetTextColor(hdc, colorref);
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        // size 0 keeps the HDC's current (UI) font; size>0 makes a sized font so text scales — the
        // font-chooser preview.  cHeight is negated (character/em height, so `size` reads as a point-ish
        // size like the GEM/Cocoa backends).  Restore + delete the temporary so nothing leaks.
        pointer fnt = (pointer)0;
        pointer old = (pointer)0;
        if (size > (i32)0)
            {
            fnt = CreateFontA((i32)0 - size, (i32)0, (i32)0, (i32)0, (i32)400,
                              (u32)0, (u32)0, (u32)0, (u32)1, (u32)0, (u32)0, (u32)0, (u32)0, (u8*)"");
            old = SelectObject(hdc, fnt);
            }
        TextOutA(hdc, (i32)(origin.x + x), (i32)(origin.y + y), (pointer)s, n);
        if (fnt != (pointer)0)
            {
            SelectObject(hdc, old);
            DeleteObject(fnt);
            }
        }

    // Styled text: a real named family at a size, bold/italic — the font-chooser preview.  GDI substitutes
    // a close face when the exact family is not installed.  cHeight is negated (character/em height).
    void drawTextFont(u8* s, i16 x, i16 y, i32 pen, u8* family, i32 size, bool bold, bool italic)
        {
        SetBkMode(hdc, (i32)TRANSPARENT);
        SetTextColor(hdc, self.penColor(pen));
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        i32 h = (i32)0 - (size > (i32)0 ? size : (i32)12);
        pointer fnt = CreateFontA(h, (i32)0, (i32)0, (i32)0, bold ? (i32)700 : (i32)400,
                                  italic ? (u32)1 : (u32)0, (u32)0, (u32)0, (u32)1, (u32)0, (u32)0, (u32)0, (u32)0, family);
        pointer old = SelectObject(hdc, fnt);
        TextOutA(hdc, (i32)(origin.x + x), (i32)(origin.y + y), (pointer)s, n);
        SelectObject(hdc, old);
        DeleteObject(fnt);
        }
    // A family at a numeric WEIGHT: GDI's CreateFontA takes the 0..1000 weight directly, so the CSS
    // 600 goes through as 600 and the face is the nearest the family has.  Alpha is dropped with the
    // rest of GDI's compositing; see blendsAlpha.
    void drawTextFontRGBA(u8* s, i16 x, i16 y, u8* family, i32 size, i32 weight, bool italic,
                          i32 red, i32 green, i32 blue, i32 alpha)
        {
        SetBkMode(hdc, (i32)TRANSPARENT);
        SetTextColor(hdc, (u32)((u32)red | ((u32)green << (u32)8) | ((u32)blue << (u32)16)));
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        i32 h = (i32)0 - (size > (i32)0 ? size : (i32)12);
        i32 w = weight > (i32)0 ? weight : (i32)400;
        pointer fnt = CreateFontA(h, (i32)0, (i32)0, (i32)0, w,
                                  italic ? (u32)1 : (u32)0, (u32)0, (u32)0, (u32)1, (u32)0, (u32)0, (u32)0, (u32)0, family);
        pointer old = SelectObject(hdc, fnt);
        TextOutA(hdc, (i32)(origin.x + x), (i32)(origin.y + y), (pointer)s, n);
        SelectObject(hdc, old);
        DeleteObject(fnt);
        }

    void fillTriangle(i16 x0, i16 y0, i16 x1, i16 y1, i16 x2, i16 y2, i32 pen)
        {
        POINT pts[3];
        pts[0].x = (i32)(origin.x + x0);
        pts[0].y = (i32)(origin.y + y0);
        pts[1].x = (i32)(origin.x + x1);
        pts[1].y = (i32)(origin.y + y1);
        pts[2].x = (i32)(origin.x + x2);
        pts[2].y = (i32)(origin.y + y2);
        pointer br = CreateSolidBrush(self.penColor(pen));
        pointer old = SelectObject(hdc, br);
        Polygon(hdc, (pointer)&pts[0], (i32)3);
        SelectObject(hdc, old);
        DeleteObject(br);
        }
    void fillPolygon(i16* xy, i32 n, i32 pen)
        {
        self.fillPoly(xy, n, self.penColor(pen));
        }
    void fillPolygonRGB(i16* xy, i32 n, i32 red, i32 green, i32 blue)
        {
        self.fillPoly(xy, n, (u32)((u32)red | ((u32)green << (u32)8) | ((u32)blue << (u32)16)));
        }
    // Opaque, like every GDI fill; see blendsAlpha's note.
    void fillPolygonRGBA(i16* xy, i32 n, i32 red, i32 green, i32 blue, i32 alpha)
        {
        self.fillPolygonRGB(xy, n, red, green, blue);
        }
    // GDI wants 32-bit POINTs, so the i16 pairs are widened on the way through; 128 matches the
    // ceiling libGEM's v_fillarea imposes, so a shape that draws on one backend draws on all.
    void fillPoly(i16* xy, i32 n, u32 colorref)
        {
        if (n < (i32)3)
            {
            return;
            }
        if (n > (i32)128)
            {
            n = (i32)128;
            }
        POINT pts[128];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            pts[i].x = (i32)(origin.x + xy[i * (i32)2]);
            pts[i].y = (i32)(origin.y + xy[i * (i32)2 + (i32)1]);
            }
        pointer br = CreateSolidBrush(colorref);
        pointer old = SelectObject(hdc, br);
        pointer opn = SelectObject(hdc, GetStockObject((i32)NULL_PEN)); // fill only, no outline
        Polygon(hdc, (pointer)&pts[0], n);
        SelectObject(hdc, opn);
        SelectObject(hdc, old);
        DeleteObject(br);
        }

    // GDI strokes curves natively with a GEOMETRIC pen: PolyBezierTo draws the cubic, and the pen
    // supplies width, round joins and the cap.  That gives a true offset of the curve rather than an
    // offset of a polyline rounded to whole pixels, which is the lumpiness the neutral stroker has.
    bool strokesNatively(void)
        {
        return true;
        }
    // ...but GDI cannot DASH a geometric pen.  ExtCreatePen only accepts a style like PS_DASH on a
    // COSMETIC pen — one pixel wide, flat caps, no join — so there is no phase to hand over and the
    // run would be silently dropped, which is a solid border where a dashed one was asked for.  False
    // sends it to the neutral dasher instead: the flattened centreline, coarser, but the right picture
    // and the same picture the VDI draws.
    bool dashesNatively(void)
        {
        return false;
        }
    // A geometric pen is opaque like every other GDI brush; see blendsAlpha's note.
    bool blendsAlpha(void)
        {
        return false;
        }
    void strokeNative(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                      i32* dash, i32 ndash, i32 phase, i32 pen)
        {
        self.strokeOps(ops, n, width, startCap, endCap, join, self.penColor(pen));
        }
    void strokeNativeRGB(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                         i32* dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue)
        {
        self.strokeOps(ops, n, width, startCap, endCap, join,
                       (u32)((u32)red | ((u32)green << (u32)8) | ((u32)blue << (u32)16)));
        }
    void strokeNativeRGBA(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                          i32* dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue, i32 alpha)
        {
        self.strokeNativeRGB(ops, n, width, startCap, endCap, join, dash, ndash, phase,
                             red, green, blue);
        }
    void strokeOps(i32* ops, i32 n, double widthFx, i32 startCap, i32 endCap, i32 join, u32 colorref)
        {
        // ExtCreatePen's width is a whole number of pixels, so a fractional pen rounds here — the
        // coarse-but-honest half of the seam's width rule (see UXGraphics' strokeNative comment).
        i32 width = (i32)(widthFx + 0.5);
        if (n <= (i32)0 || width <= (i32)0)
            {
            return;
            }
        LOGBRUSH lb;
        lb.lbStyle = (u32)BS_SOLID;
        lb.lbColor = colorref;
        lb.lbHatch = (pointer)0;
        // One cap for the whole path, as GDI has it: the rounder of the two ends wins and the other is
        // covered by whatever the painter draws there (an arrowhead, or nothing for a butt end).
        i32 cap = startCap > endCap ? startCap : endCap;
        u32 capBit = cap == (i32)1 ? (u32)PS_ENDCAP_ROUND
                                   : (cap == (i32)2 ? (u32)PS_ENDCAP_SQUARE : (u32)PS_ENDCAP_FLAT);
        // join: 0 miter, 1 round, 2 bevel (UXJOIN_*)
        u32 joinBit = join == (i32)0 ? (u32)PS_JOIN_MITER
                                    : (join == (i32)2 ? (u32)PS_JOIN_BEVEL : (u32)PS_JOIN_ROUND);
        pointer pn = ExtCreatePen((u32)PS_GEOMETRIC | (u32)PS_SOLID | capBit | joinBit,
                                  (u32)width, (pointer)&lb, (u32)0, (pointer)0);
        if (pn == (pointer)0)
            {
            return;
            }
        pointer old = SelectObject(hdc, pn);
        i32 ox = (i32)origin.x;
        i32 oy = (i32)origin.y;
        POINT bez[3];
        i32 i = (i32)0;
        i32 sx = (i32)0;
        i32 sy = (i32)0;
        bool started = false;
        while (i < n)
            {
            i32 op = ops[i];
            i = i + (i32)1;
            if (op == (i32)UXSTROKE_MOVE)
                {
                if (i + (i32)2 > n)
                    {
                    break;
                    }
                sx = ox + ops[i];
                sy = oy + ops[i + (i32)1];
                MoveToEx(hdc, sx, sy, (pointer)0);
                i = i + (i32)2;
                started = true;
                }
            else if (op == (i32)UXSTROKE_LINE)
                {
                if (i + (i32)2 > n)
                    {
                    break;
                    }
                if (!started)
                    {
                    sx = ox + ops[i];
                    sy = oy + ops[i + (i32)1];
                    MoveToEx(hdc, sx, sy, (pointer)0);
                    started = true;
                    }
                else
                    {
                    LineTo(hdc, ox + ops[i], oy + ops[i + (i32)1]);
                    }
                i = i + (i32)2;
                }
            else if (op == (i32)UXSTROKE_CURVE)
                {
                if (i + (i32)6 > n)
                    {
                    break;
                    }
                if (!started)
                    {
                    sx = ox + ops[i + (i32)4];
                    sy = oy + ops[i + (i32)5];
                    MoveToEx(hdc, sx, sy, (pointer)0);
                    started = true;
                    }
                else
                    {
                    bez[0].x = ox + ops[i];
                    bez[0].y = oy + ops[i + (i32)1];
                    bez[1].x = ox + ops[i + (i32)2];
                    bez[1].y = oy + ops[i + (i32)3];
                    bez[2].x = ox + ops[i + (i32)4];
                    bez[2].y = oy + ops[i + (i32)5];
                    PolyBezierTo(hdc, (pointer)&bez[0], (u32)3);
                    }
                i = i + (i32)6;
                }
            else if (op == (i32)UXSTROKE_CLOSE)
                {
                if (started)
                    {
                    LineTo(hdc, sx, sy);
                    }
                }
            else
                {
                break;
                }
            }
        SelectObject(hdc, old);
        DeleteObject(pn);
        }

    // Crude stand-ins — Win32 check/radio are NATIVE controls, so these only run in headless tests.
    void fillCircle(i16 cx, i16 cy, i16 r, i32 pen)
        {
        self.fillRect(UXGeom.make((i16)(cx - r), (i16)(cy - r), (i16)(r + r), (i16)(r + r)), pen);
        }
    // A 2px stroked segment (matches GEM's vsl_width 2).  The toolkit's lines — frame edges, rules — are
    // axis-aligned, so draw those as proper filled bars; keep a thin parallelogram for the rare diagonal
    // (checkmark strokes, which are native-drawn on Win32 anyway).  The old triangle fake made a wedge —
    // a point on the left growing to 2px on the right — so every rectangle looked heavier on the right.
    void drawLine(i16 x0, i16 y0, i16 x1, i16 y1, i32 pen)
        {
        // horizontal
        if (y0 == y1)
            {
            i16 lx = x0 < x1 ? x0 : x1;
            i16 rx = x0 < x1 ? x1 : x0;
            self.fillRect(UXGeom.make(lx, y0, (i16)((i32)rx - (i32)lx + (i32)1), (i16)2), pen);
            }
        // vertical
        else if (x0 == x1)
            {
            i16 ty = y0 < y1 ? y0 : y1;
            i16 by = y0 < y1 ? y1 : y0;
            self.fillRect(UXGeom.make(x0, ty, (i16)2, (i16)((i32)by - (i32)ty + (i32)1)), pen);
            }
        // diagonal: a 2px-tall parallelogram
        else
            {
            POINT pts[4];
            pts[0].x = (i32)(origin.x + x0);
            pts[0].y = (i32)(origin.y + y0);
            pts[1].x = (i32)(origin.x + x1);
            pts[1].y = (i32)(origin.y + y1);
            pts[2].x = (i32)(origin.x + x1);
            pts[2].y = (i32)(origin.y + y1 + (i16)2);
            pts[3].x = (i32)(origin.x + x0);
            pts[3].y = (i32)(origin.y + y0 + (i16)2);
            pointer br = CreateSolidBrush(self.penColor(pen));
            pointer old = SelectObject(hdc, br);
            Polygon(hdc, (pointer)&pts[0], (i32)4);
            SelectObject(hdc, old);
            DeleteObject(br);
            }
        }
    }
