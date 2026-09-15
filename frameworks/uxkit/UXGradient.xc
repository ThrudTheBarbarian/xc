// UXGradient.xc — a colour gradient sampled by position (NSGradient in shape).
//
// A sorted list of colour STOPS at positions 0..255; colorAt(t) finds the bracketing pair and blends
// them with UXColor.blend.  Before the first stop it clamps to the first colour, after the last to the
// last.  Integer maths throughout, so a themed button fill or a background sweep samples identically on
// every backend.  Drawing the sampled colours is the backend's job; this computes them.
#import "Array.xc"
#import "UXColor.xc"

class UXGradientStop : Object
    {
    i32 pos; // 0..255
    UXColor* color;
    void init(void)
        {
        pos = (i32)0;
        color = (UXColor*)0;
        }
    }

    class UXGradient
    {
    Array<UXGradientStop>* stops; // sorted by pos ascending
    void init(void)
        {
        stops = new Array();
        }

    void addStop(i32 pos, UXColor* c)
        {
        if (pos < (i32)0)
            {
            pos = (i32)0;
            }
        if (pos > (i32)255)
            {
            pos = (i32)255;
            }
        UXGradientStop* s = new UXGradientStop();
        s.pos = pos;
        s.color = c;
        u16 at = (u16)0;
        while (at < stops.count() && ((UXGradientStop* ?)stops.get(at)).pos <= pos)
            {
            at = at + (u16)1;
            }
        stops.insert(at, s);
        }
    i32 stopCount(void)
        {
        return (i32)stops.count();
        }
    UXGradientStop* stopAt(i32 i)
        { return (UXGradientStop* ?)stops.get((u16)i);
        }

    static UXGradient* twoColor(UXColor* a, UXColor* b)
        {
        UXGradient* g = new UXGradient();
        g.addStop((i32)0, a);
        g.addStop((i32)255, b);
        return g;
        }

    // Sample the gradient at t (0..255).
    UXColor* colorAt(i32 t)
        {
        i32 n = (i32)stops.count();
        if (n == (i32)0)
            {
            return UXColor.black();
            }
        if (t <= self.stopAt((i32)0).pos)
            {
            return self.stopAt((i32)0).color;
            }
        if (t >= self.stopAt(n - (i32)1).pos)
            {
            return self.stopAt(n - (i32)1).color;
            }
        for (i32 i = (i32)0; i < n - (i32)1; i = i + (i32)1)
            {
            UXGradientStop* s0 = self.stopAt(i);
            UXGradientStop* s1 = self.stopAt(i + (i32)1);
            if (t >= s0.pos && t < s1.pos)
                {
                i32 span = s1.pos - s0.pos;
                i32 local = span > (i32)0 ? (t - s0.pos) * (i32)255 / span : (i32)0;
                return s0.color.blend(s1.color, local);
                }
            }
        return self.stopAt(n - (i32)1).color;
        }
    }
