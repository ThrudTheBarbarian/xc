// UXStepper.xc — an increment/decrement stepper (NSStepper in shape).
//
// A small two-part control: the top half steps the value up, the bottom half down, clamped to a range
// (or wrapping).  Often paired with a text field.  The value logic is pure and unit-testable; drawing
// + the up/down hit-test ride the UXControl seam.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

class UXStepper : UXControl
    {
    i32 value;
    i32 minVal;
    i32 maxVal;
    i32 step;
    bool wraps;
    void init(void)
        {
        super.init();
        value = (i32)0;
        minVal = (i32)0;
        maxVal = (i32)100;
        step = (i32)1;
        wraps = false;
        }
    // native NSStepper; drawRect is the GEM fallback
    UXKind kind(void)
        {
        return UXKindStepper;
        }

    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setPeerOf(index, (pointer)self);
        }

    // ---- native-control bridge -----------------------------------------------
    i32 nativeMin(void)
        {
        return minVal;
        }
    i32 nativeMax(void)
        {
        return maxVal;
        }
    i32 nativeStep(void)
        {
        return step;
        }
    bool nativeWraps(void)
        {
        return wraps;
        }
    i32 nativeValue(void)
        {
        return value;
        }
    void applyNativeValue(i32 v)
        {
        self.setValue(v);
        }

    void setRange(i32 lo, i32 hi)
        {
        minVal = lo;
        maxVal = hi > lo ? hi : lo;
        self.clamp();
        }
    void setStep(i32 s)
        {
        step = s > (i32)0 ? s : (i32)1;
        }
    void setWraps(bool w)
        {
        wraps = w;
        }
    void setValue(i32 v)
        {
        value = v;
        self.clamp();
        }
    i32 intValue(void)
        {
        return value;
        }
    void clamp(void)
        {
        if (value < minVal)
            {
            value = minVal;
            }
        if (value > maxVal)
            {
            value = maxVal;
            }
        }

    void increment(void)
        {
        value = value + step;
        if (value > maxVal)
            {
            value = wraps ? minVal : maxVal;
            }
        }
    void decrement(void)
        {
        value = value - step;
        if (value < minVal)
            {
            value = wraps ? maxVal : minVal;
            }
        }

    void mouseDown(UXEvent* e)
        {
        if (!self.isEnabled())
            {
            return;
            }
        UXRect abs = self.absoluteFrame();
        i16 ly = (i16)((i32)e.y - abs.y);
        if ((i32)ly < abs.h / (i32)2)
            {
            self.increment();
            }
        // top up, bottom down
        else
            {
            self.decrement();
            }
        self.setNeedsDisplay();
        self.fire();
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        // Themed up/down bezels at their NATURAL 25x25 (13+12), centred in the
        // frame — the checkbox's fixed-sprite rule: stretching pixel art to
        // the frame blurs it and turns the narrow pair into a squat slab.
        // (Aristo2 on GEM/web; native NSStepper/up-down elsewhere skip this.)
        i16 ax = (i16)(((i32)b.w - (i32)25) / (i32)2);
        if (ax < (i16)0)
            {
            ax = (i16)0;
            }
        i16 ay = (i16)(((i32)b.h - (i32)25) / (i32)2);
        if (ay < (i16)0)
            {
            ay = (i16)0;
            }
        g.drawTheme((u8*)"stepper.up", UXGeom.make(ax, ay, (i16)25, (i16)13));
        g.drawTheme((u8*)"stepper.down", UXGeom.make(ax, (i16)(ay + (i16)13), (i16)25, (i16)12));
        }
    }
