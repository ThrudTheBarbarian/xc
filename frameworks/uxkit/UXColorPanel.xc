// UXColorPanel.xc — the model behind a colour picker (NSColorPanel, HSB mode).
//
// Holds hue / saturation / brightness (and alpha) and stays in sync with an UXColor: set a component
// (a slider drag) and color() recomposes; set a colour (an eyedropper / swatch) and it decomposes to
// HSB.  Reuses UXColor's integer HSB<->RGB.  The panel VIEW (the sliders + the 2-D field) draws this;
// the picking state + conversions live here and are testable.
#import "Array.xc"
#import "UXColor.xc"

class UXColorPanel
    {
    i32 hue;   // 0..359
    i32 sat;   // 0..255
    i32 bri;   // 0..255
    i32 alpha; // 0..255
    void init(void)
        {
        hue = (i32)0;
        sat = (i32)0;
        bri = (i32)0;
        alpha = (i32)255;
        }

    // Adopt a colour: decompose to HSB, keep its alpha.
    void setColor(UXColor* c)
        {
        i32 h = (i32)0;
        i32 s = (i32)0;
        i32 v = (i32)0;
        c.toHSB(&h, &s, &v);
        hue = h;
        sat = s;
        bri = v;
        alpha = c.a;
        }
    // The current colour, composed from HSB + alpha.
    UXColor* color(void)
        {
        UXColor* c = UXColor.hsb(hue, sat, bri);
        return c.withAlpha(alpha);
        }

    void setHue(i32 h)
        {
        hue = ((h % (i32)360) + (i32)360) % (i32)360;
        }
    void setSaturation(i32 s)
        {
        sat = UXColor.clamp(s);
        }
    void setBrightness(i32 b)
        {
        bri = UXColor.clamp(b);
        }
    void setAlpha(i32 a)
        {
        alpha = UXColor.clamp(a);
        }

    i32 hueValue(void)
        {
        return hue;
        }
    i32 saturationValue(void)
        {
        return sat;
        }
    i32 brightnessValue(void)
        {
        return bri;
        }
    i32 alphaValue(void)
        {
        return alpha;
        }

    // A hex string preview of the current colour (0xRRGGBB via UXColor).
    u32 hex(void)
        {
        return self.color().toHex();
        }
    }
