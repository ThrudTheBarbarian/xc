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

    // The VDI has vsl_width for straight polylines but nothing that strokes a CURVE at width, and no
    // round join or cap — so GEM keeps UXPainter's own stroker.  On hard pixels that is the right
    // answer anyway: the half-pixel wobble that makes the neutral stroker look lumpy under Cocoa's
    // antialiasing lands inside the pixel grid here and cannot be seen.
    bool strokesNatively(void)
        {
        return false;
        }
    void strokeNative(i32* ops, i32 n, i32 width, i32 startCap, i32 endCap, i32 pen)
        {
        }
    void strokeNativeRGB(i32* ops, i32 n, i32 width, i32 startCap, i32 endCap,
                         i32 red, i32 green, i32 blue)
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
