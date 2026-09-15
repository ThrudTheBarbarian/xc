// UXColor.xc — an RGBA colour value type (NSColor/CGColor in shape), neutral across backends.
//
// Components are 0..255 integers; HSB uses hue 0..359, saturation/brightness 0..255.  Conversions are
// integer-only (the classic HSV<->RGB algorithm) so they are exact and identical on every backend — no
// soft-float differences between arm9, win64 and mac.  This is the value the future colour panel edits
// and drawing will take, sitting above the driver's coarse VDI-pen palette.
//
//     UXColor* c = UXColor.rgb((i32)0, (i32)122, (i32)255);   // a blue
//     u32 hex = c.toHex();                                     // 0x007AFF
//     UXColor* d = c.darkened((i32)40);                        // 40/255 toward black
#import "Array.xc"

class UXColor
    {
    i32 r;
    i32 g;
    i32 b;
    i32 a; // 0..255

    void init(void)
        {
        r = (i32)0;
        g = (i32)0;
        b = (i32)0;
        a = (i32)255;
        }

    static i32 clamp(i32 v)
        {
        if (v < (i32)0)
            {
            return (i32)0;
            }
        if (v > (i32)255)
            {
            return (i32)255;
            }
        return v;
        }

    static UXColor* rgba(i32 r, i32 g, i32 b, i32 a)
        {
        UXColor* c = new UXColor();
        c.r = UXColor.clamp(r);
        c.g = UXColor.clamp(g);
        c.b = UXColor.clamp(b);
        c.a = UXColor.clamp(a);
        return c;
        }
    static UXColor* rgb(i32 r, i32 g, i32 b)
        {
        return UXColor.rgba(r, g, b, (i32)255);
        }
    // 0xRRGGBB (opaque)
    static UXColor* fromHex(u32 hex)
        {
        return UXColor.rgb((i32)((hex >> (u32)16) & (u32)255),
                           (i32)((hex >> (u32)8) & (u32)255),
                           (i32)(hex & (u32)255));
        }
    // 0xAARRGGBB
    static UXColor* fromHexA(u32 hex)
        {
        return UXColor.rgba((i32)((hex >> (u32)16) & (u32)255),
                            (i32)((hex >> (u32)8) & (u32)255),
                            (i32)(hex & (u32)255),
                            (i32)((hex >> (u32)24) & (u32)255));
        }
    u32 toHex(void)
        {
        return ((u32)r << (u32)16) | ((u32)g << (u32)8) | (u32)b;
        }

    // ---- HSB (integer) -------------------------------------------------------
    // hue 0..359, sat 0..255, bri 0..255.
    static UXColor* hsb(i32 h, i32 s, i32 v)
        {
        h = ((h % (i32)360) + (i32)360) % (i32)360;
        s = UXColor.clamp(s);
        v = UXColor.clamp(v);
        // grey
        if (s == (i32)0)
            {
            return UXColor.rgb(v, v, v);
            }
        i32 region = h / (i32)60; // 0..5
        i32 f = h % (i32)60;      // 0..59 within the region
        i32 p = v * ((i32)255 - s) / (i32)255;
        i32 q = v * ((i32)255 - s * f / (i32)60) / (i32)255;
        i32 t = v * ((i32)255 - s * ((i32)60 - f) / (i32)60) / (i32)255;
        if (region == (i32)0)
            {
            return UXColor.rgb(v, t, p);
            }
        if (region == (i32)1)
            {
            return UXColor.rgb(q, v, p);
            }
        if (region == (i32)2)
            {
            return UXColor.rgb(p, v, t);
            }
        if (region == (i32)3)
            {
            return UXColor.rgb(p, q, v);
            }
        if (region == (i32)4)
            {
            return UXColor.rgb(t, p, v);
            }
        return UXColor.rgb(v, p, q);
        }
    // Decompose into hue/sat/bri (0..359, 0..255, 0..255).
    void toHSB(i32* h, i32* s, i32* v)
        {
        i32 mx = r;
        if (g > mx)
            {
            mx = g;
            }
        if (b > mx)
            {
            mx = b;
            }
        i32 mn = r;
        if (g < mn)
            {
            mn = g;
            }
        if (b < mn)
            {
            mn = b;
            }
        i32 delta = mx - mn;
        v[0] = mx;
        s[0] = mx == (i32)0 ? (i32)0 : delta * (i32)255 / mx;
        if (delta == (i32)0)
            {
            h[0] = (i32)0;
            return;
            }
        i32 hue;
        if (mx == r)
            {
            hue = (i32)60 * (g - b) / delta;
            }
        else if (mx == g)
            {
            hue = (i32)60 * (b - r) / delta + (i32)120;
            }
        else
            {
            hue = (i32)60 * (r - g) / delta + (i32)240;
            }
        h[0] = ((hue % (i32)360) + (i32)360) % (i32)360;
        }

    // ---- operations ----------------------------------------------------------
    // Linear blend toward `other`, t in 0..255 (0 = self, 255 = other).
    UXColor* blend(UXColor* other, i32 t)
        {
        t = UXColor.clamp(t);
        i32 u = (i32)255 - t;
        return UXColor.rgba((r * u + other.r * t) / (i32)255,
                            (g * u + other.g * t) / (i32)255,
                            (b * u + other.b * t) / (i32)255,
                            (a * u + other.a * t) / (i32)255);
        }
    UXColor* lightened(i32 amt)
        {
        return self.blend(UXColor.rgb((i32)255, (i32)255, (i32)255), amt);
        }
    UXColor* darkened(i32 amt)
        {
        return self.blend(UXColor.rgb((i32)0, (i32)0, (i32)0), amt);
        }
    UXColor* withAlpha(i32 alpha)
        {
        return UXColor.rgba(r, g, b, alpha);
        }

    // Perceptual luminance 0..255 (Rec. 601 weights) — for picking readable text over this colour.
    i32 luminance(void)
        {
        return ((i32)77 * r + (i32)150 * g + (i32)29 * b) / (i32)256;
        }
    bool isDark(void)
        {
        return self.luminance() < (i32)128;
        }

    // not `equals` — that is Object's pointer identity
    bool isEqualTo(UXColor* o)
        {
        return o != (UXColor*)0 && r == o.r && g == o.g && b == o.b && a == o.a;
        }

    // ---- named colours -------------------------------------------------------
    static UXColor* black(void)
        {
        return UXColor.rgb((i32)0, (i32)0, (i32)0);
        }
    static UXColor* white(void)
        {
        return UXColor.rgb((i32)255, (i32)255, (i32)255);
        }
    static UXColor* red(void)
        {
        return UXColor.rgb((i32)255, (i32)0, (i32)0);
        }
    static UXColor* green(void)
        {
        return UXColor.rgb((i32)0, (i32)255, (i32)0);
        }
    static UXColor* blue(void)
        {
        return UXColor.rgb((i32)0, (i32)0, (i32)255);
        }
    static UXColor* yellow(void)
        {
        return UXColor.rgb((i32)255, (i32)255, (i32)0);
        }
    static UXColor* gray(void)
        {
        return UXColor.rgb((i32)128, (i32)128, (i32)128);
        }
    static UXColor* clear(void)
        {
        return UXColor.rgba((i32)0, (i32)0, (i32)0, (i32)0);
        }
    }
