// UXGemGraphics.xc — the GEM/VDI realization of UXGraphics.
//
// Thin by design: it is the AES's own VDI workstation plus the theme.  An UXView that draws
// itself uses exactly the same calls objc_draw uses for a G_BUTTON, so custom views and
// stock widgets are pixel-consistent by construction.  A host backend is a sibling of this
// file (GDI / CoreGraphics) implementing the same UXGraphics protocol.
#import "UXGem.h.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"

class UXGemGraphics : Object<UXGraphics>
    {
    i32 vh;        // the AES's workstation — aes_handle()
    pointer th;    // the loaded theme
    UXRect origin; // absolute position of the view being drawn

    void init(void)
        {
        vh = (i32)0;
        th = (pointer)0;
        origin = UXGeom.zero();
        }

    // The GEM draw seam binds the context to this paint: the workstation, the theme, and the
    // view's absolute origin.  (Backend setup, not part of the neutral protocol.)
    void bind(i32 handle, pointer theme, UXRect abs)
        {
        vh = handle;
        th = theme;
        origin = abs;
        }
    bool hasThemeArt(void)
        {
        return true;
        }

    void fillRect(UXRect r, i32 pen)
        {
        i16 pxy[4];
        pxy[0] = (i16)(origin.x + r.x);
        pxy[1] = (i16)(origin.y + r.y);
        pxy[2] = (i16)(origin.x + r.x + r.w - (i16)1);
        pxy[3] = (i16)(origin.y + r.y + r.h - (i16)1);
        vsf_color(vh, pen);
        vsf_interior(vh, (i32)1);
        vsf_perimeter(vh, (i32)0);
        vr_recfl(vh, (pointer)&pxy[0]);
        }

    // True-colour fill: the platform is 32-bit RGBA, so set a scratch pen (255) straight from RGB via
    // v_setrgb and fill with it.  We re-set it every call, so nothing else can depend on pen 255.
    void fillRectRGB(UXRect r, i32 red, i32 green, i32 blue)
        {
        i16 pxy[4];
        pxy[0] = (i16)(origin.x + r.x);
        pxy[1] = (i16)(origin.y + r.y);
        pxy[2] = (i16)(origin.x + r.x + r.w - (i16)1);
        pxy[3] = (i16)(origin.y + r.y + r.h - (i16)1);
        v_setrgb(vh, (i32)255, red, green, blue);
        vsf_color(vh, (i32)255);
        vsf_interior(vh, (i32)1);
        vsf_perimeter(vh, (i32)0);
        vr_recfl(vh, (pointer)&pxy[0]);
        }
    // The VDI has no compositing: a pen is a palette entry and a fill replaces what is under it.
    // blendsAlpha() answers false, and the colour is drawn opaque rather than pretending otherwise.
    void fillRectRGBA(UXRect r, i32 red, i32 green, i32 blue, i32 alpha)
        {
        self.fillRectRGB(r, red, green, blue);
        }
    // A bitmap region, scaled, with alpha.  The VDI copies rasters but neither scales nor blends, so this
    // is a read-modify-write of the destination: copy it out of the surface (vro_cpyfm, screen -> a
    // scratch raster), blend the source over it here -- nearest sampling, straight alpha -- and copy it
    // back, which the ws clip cuts to the view.  The surface's pixels are 0xRRGGBBAA words.
    void drawPixels(u8* data, i32 w, i32 h, i32 format, UXRect src, UXRect dst, i32 alpha)
        {
        i32 sx = (i32)src.x;
        i32 sy = (i32)src.y;
        i32 sw = (i32)src.w;
        i32 sh = (i32)src.h;
        if (sx < (i32)0)
            {
            sw = sw + sx;
            sx = (i32)0;
            }
        if (sy < (i32)0)
            {
            sh = sh + sy;
            sy = (i32)0;
            }
        if (sx + sw > w)
            {
            sw = w - sx;
            }
        if (sy + sh > h)
            {
            sh = h - sy;
            }
        i32 dw = (i32)dst.w;
        i32 dh = (i32)dst.h;
        if (data == (u8*)0 || alpha <= (i32)0 || sw <= (i32)0 || sh <= (i32)0 || dw <= (i32)0 || dh <= (i32)0)
            {
            return;
            }
        if (alpha > (i32)255)
            {
            alpha = (i32)255;
            }
        u32* buf = (u32*)malloc((u32)(dw * dh * (i32)4));
        if (buf == (u32*)0)
            {
            return;
            }
        i32 dx = (i32)origin.x + (i32)dst.x;
        i32 dy = (i32)origin.y + (i32)dst.y;
        MFDB screen;
        screen.addr = (u32*)0;
        MFDB mem;
        mem.addr = buf;
        mem.w = (i16)dw;
        mem.h = (i16)dh;
        mem.stride = (i16)dw;
        mem.nplanes = (i16)32;
        mem.stand = (i16)0;
        i16 pxy[8];
        pxy[0] = (i16)dx;
        pxy[1] = (i16)dy;
        pxy[2] = (i16)(dx + dw - (i32)1);
        pxy[3] = (i16)(dy + dh - (i32)1);
        pxy[4] = (i16)0;
        pxy[5] = (i16)0;
        pxy[6] = (i16)(dw - (i32)1);
        pxy[7] = (i16)(dh - (i32)1);
        vro_cpyfm(vh, (i32)VRO_COPY, (pointer)&pxy[0], (pointer)&screen, (pointer)&mem); // what is under
        for (i32 y = (i32)0; y < dh; y = y + (i32)1)
            {
            i32 v = sy + (y * sh) / dh;
            for (i32 x = (i32)0; x < dw; x = x + (i32)1)
                {
                i32 u = sx + (x * sw) / dw;
                u8* q = data + (v * w + u) * (i32)4;
                i32 r = format == (i32)UXPIX_ARGB32 ? (i32)q[2] : (i32)q[0];
                i32 g = (i32)q[1];
                i32 b = format == (i32)UXPIX_ARGB32 ? (i32)q[0] : (i32)q[2];
                i32 a = ((i32)q[3] * alpha + (i32)127) / (i32)255;
                if (a == (i32)0)
                    {
                    continue;
                    }
                i32 k = y * dw + x;
                if (a < (i32)255)
                    {
                    u32 d = buf[k];
                    i32 ia = (i32)255 - a;
                    r = (r * a + (i32)((d >> (u32)24) & (u32)255) * ia + (i32)127) / (i32)255;
                    g = (g * a + (i32)((d >> (u32)16) & (u32)255) * ia + (i32)127) / (i32)255;
                    b = (b * a + (i32)((d >> (u32)8) & (u32)255) * ia + (i32)127) / (i32)255;
                    }
                buf[k] = ((u32)r << (u32)24) | ((u32)g << (u32)16) | ((u32)b << (u32)8) | (u32)255;
                }
            }
        pxy[0] = (i16)0;
        pxy[1] = (i16)0;
        pxy[2] = (i16)(dw - (i32)1);
        pxy[3] = (i16)(dh - (i32)1);
        pxy[4] = (i16)dx;
        pxy[5] = (i16)dy;
        pxy[6] = (i16)(dx + dw - (i32)1);
        pxy[7] = (i16)(dy + dh - (i32)1);
        vro_cpyfm(vh, (i32)VRO_COPY, (pointer)&pxy[0], (pointer)&mem, (pointer)&screen);
        free((pointer)buf);
        }
    // No alpha on the VDI, so "empty" is the window background the AES paints — pen 0, the white a
    // G_BOX fills with.  A layer that needs to be see-through takes the other path at blendsAlpha.
    void clearRect(UXRect r)
        {
        self.fillRect(r, (i32)0);
        }

    // A 9-slice from the theme — the same call the AES makes for stock widgets.
    void drawTheme(u8* slice, UXRect r)
        {
        theme_draw(vh, th, slice,
                   (i32)(origin.x + r.x), (i32)(origin.y + r.y), (i32)r.w, (i32)r.h);
        }

    void drawText(u8* s, i16 x, i16 y, i32 pen, i32 size)
        {
        vst_color(vh, pen);
        // size 0 means "the UI default".  vst_height treats px<1 as a no-op (it keeps the workstation's
        // last size), so passing 0 would leak a previous large size into every following string — map it
        // to the VDI default (16px) explicitly so each call is self-contained.  size>0 scales (the preview).
        vst_height(vh, size > (i32)0 ? size : (i32)16, (pointer)0, (pointer)0, (pointer)0, (pointer)0);
        v_gtext(vh, (i32)(origin.x + x), (i32)(origin.y + y), s);
        }
    // True-colour text: the same scratch pen the fills use, so the glyphs take the colour.  The alpha
    // is dropped with the rest — the VDI has no compositing.
    void drawTextRGBA(u8* s, i16 x, i16 y, i32 red, i32 green, i32 blue, i32 alpha, i32 size)
        {
        v_setrgb(vh, (i32)255, red, green, blue);
        self.drawText(s, x, y, (i32)255, size);
        }

    // Styled text: pick the registry face whose name matches `family` (vst_font), synthesise bold/italic
    // (vst_effects: FX_BOLD 0x01 | FX_ITALIC 0x04), size it (vst_height), then restore the workstation
    // state — effects and the selected face are sticky ws state, so a leak would tint every later string.
    static bool streq(u8* a, u8* b)
        {
        i32 i = (i32)0;
        while (a[i] != (u8)0 && b[i] != (u8)0)
            {
            if (a[i] != b[i])
                {
                return false;
                }
            i = i + (i32)1;
            }
        return a[i] == b[i];
        }
    i32 fontIdFor(u8* family)
        {
        // id 1 (system) + up to MAX_EXTRA (32)
        for (i32 id = (i32)1; id <= (i32)33; id = id + (i32)1)
            {
            u8* nm = vdi_font_name(id);
            // past the last mapped face
            if (nm[(i32)0] == (u8)0)
                {
                return (i32)1;
                }
            if (UXGemGraphics.streq(nm, family))
                {
                return id;
                }
            }
        return (i32)1; // unknown family -> the system face
        }
    void drawTextFont(u8* s, i16 x, i16 y, i32 pen, u8* family, i32 size, bool bold, bool italic)
        {
        vst_color(vh, pen);
        vst_font(vh, self.fontIdFor(family));
        vst_height(vh, size > (i32)0 ? size : (i32)16, (pointer)0, (pointer)0, (pointer)0, (pointer)0);
        i32 fx = (i32)0;
        if (bold)
            {
            fx = fx | (i32)1;
            }
        if (italic)
            {
            fx = fx | (i32)4;
            }
        vst_effects(vh, fx);
        v_gtext(vh, (i32)(origin.x + x), (i32)(origin.y + y), s);
        vst_effects(vh, (i32)0); // reset ws state
        vst_font(vh, (i32)1);
        }
    // A family at a numeric weight with a true colour.  The VDI has one loaded face per family and
    // only a synthetic bold, so a weight at or above semibold sets FX_BOLD and a lighter one does not
    // — the nearest the VDI can do — and the colour rides the same scratch pen the RGB fills use.
    // Alpha is dropped; see blendsAlpha.
    void drawTextFontRGBA(u8* s, i16 x, i16 y, u8* family, i32 size, i32 weight, bool italic,
                          i32 red, i32 green, i32 blue, i32 alpha)
        {
        v_setrgb(vh, (i32)255, red, green, blue);
        vst_color(vh, (i32)255);
        vst_font(vh, self.fontIdFor(family));
        vst_height(vh, size > (i32)0 ? size : (i32)16, (pointer)0, (pointer)0, (pointer)0, (pointer)0);
        i32 fx = (i32)0;
        if (weight >= (i32)UXWEIGHT_SEMIBOLD)
            {
            fx = fx | (i32)1; // FX_BOLD
            }
        if (italic)
            {
            fx = fx | (i32)4; // FX_ITALIC
            }
        vst_effects(vh, fx);
        v_gtext(vh, (i32)(origin.x + x), (i32)(origin.y + y), s);
        vst_effects(vh, (i32)0);
        vst_font(vh, (i32)1);
        }

    // A filled triangle.  The one shape GEM has no object type for, and an outline view
    // needs it for the disclosure marker: ▶ when collapsed, ▼ when expanded.
    void fillTriangle(i16 x0, i16 y0, i16 x1, i16 y1, i16 x2, i16 y2, i32 pen)
        {
        i16 pxy[6];
        pxy[0] = (i16)(origin.x + x0);
        pxy[1] = (i16)(origin.y + y0);
        pxy[2] = (i16)(origin.x + x1);
        pxy[3] = (i16)(origin.y + y1);
        pxy[4] = (i16)(origin.x + x2);
        pxy[5] = (i16)(origin.y + y2);
        vsf_color(vh, pen);
        vsf_interior(vh, (i32)1);
        vsf_perimeter(vh, (i32)0);
        v_fillarea(vh, (i32)3, (pointer)&pxy[0]);
        }

    // v_fillarea caps at 128 vertices inside libGEM, so clamp rather than let it read past the
    // caller's array; nothing UXPainter produces comes close (a quad is 4, a join fan 10).
    void fillPolygon(i16* xy, i32 n, i32 pen)
        {
        if (n < (i32)3)
            {
            return;
            }
        if (n > (i32)128)
            {
            n = (i32)128;
            }
        i16 pxy[256];
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            pxy[i * (i32)2] = (i16)(origin.x + xy[i * (i32)2]);
            pxy[i * (i32)2 + (i32)1] = (i16)(origin.y + xy[i * (i32)2 + (i32)1]);
            }
        vsf_color(vh, pen);
        vsf_interior(vh, (i32)1);
        vsf_perimeter(vh, (i32)0);
        v_fillarea(vh, n, (pointer)&pxy[0]);
        }
    // True colour: set the pen from RGB first, then fill with it (v_setrgb writes the palette slot).
    void fillPolygonRGB(i16* xy, i32 n, i32 red, i32 green, i32 blue)
        {
        v_setrgb(vh, (i32)255, red, green, blue); // the same scratch pen fillRectRGB uses
        self.fillPolygon(xy, n, (i32)255);
        }
    void fillPolygonRGBA(i16* xy, i32 n, i32 red, i32 green, i32 blue, i32 alpha)
        {
        self.fillPolygonRGB(xy, n, red, green, blue);
        }

    // The VDI has vsl_width for straight polylines but nothing that strokes a CURVE at width, and no
    // round join or cap — so GEM keeps UXPainter's own stroker.  On hard pixels that is the right
    // answer anyway: the half-pixel wobble that makes the neutral stroker look lumpy under Cocoa's
    // antialiasing lands inside the pixel grid here and cannot be seen.
    bool strokesNatively(void)
        {
        return false;
        }
    // ...and with no curve stroker of its own the VDI has no dasher either, so a dash falls to the
    // neutral dasher — UXPainter's walk over the flattened centreline.  False rather than a silent
    // approximation here, so that the caller knows which of the two it is getting.
    bool dashesNatively(void)
        {
        return false;
        }
    // The VDI cannot blend, so a translucent layer is drawn opaque here.  Ask blendsAlpha() first.
    bool blendsAlpha(void)
        {
        return false;
        }
    // Empty, and strokesNatively() is false: the VDI has no path stroker, so UXPainter's neutral
    // stroker draws every stroke here, quantising the width to the 1/16 px it works in (UX_FX).
    void strokeNative(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                      i32* dash, i32 ndash, i32 phase, i32 pen)
        {
        }
    void strokeNativeRGB(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                         i32* dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue)
        {
        }
    void strokeNativeRGBA(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                          i32* dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue, i32 alpha)
        {
        }

    // A filled disc — the radio button's marker (GEM has a native VDI circle).
    void fillCircle(i16 cx, i16 cy, i16 r, i32 pen)
        {
        vsf_color(vh, pen);
        vsf_interior(vh, (i32)1);
        vsf_perimeter(vh, (i32)0);
        v_circle(vh, (i32)(origin.x + cx), (i32)(origin.y + cy), (i32)r);
        }
    // A 2px stroked segment (checkmark strokes, hairlines).
    void drawLine(i16 x0, i16 y0, i16 x1, i16 y1, i32 pen)
        {
        i16 pxy[4];
        pxy[0] = (i16)(origin.x + x0);
        pxy[1] = (i16)(origin.y + y0);
        pxy[2] = (i16)(origin.x + x1);
        pxy[3] = (i16)(origin.y + y1);
        vsl_color(vh, pen);
        vsl_width(vh, (i32)2);
        v_pline(vh, (i32)2, (pointer)&pxy[0]);
        }
    }
