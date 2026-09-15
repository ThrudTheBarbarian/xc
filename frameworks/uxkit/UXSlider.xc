// UXSlider.xc — a value slider (NSSlider in shape), app-drawn on every backend.
//
// A knob slides along a track; the value maps linearly to the knob position and back, so a click or
// drag sets the value and the value places the knob.  The value<->position arithmetic is pure and
// unit-testable without a window; drawing + the absolute->local click conversion ride the UXControl
// seam.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"
#import "UXApplication.xc" // gApp — repaint live mid-drag (self-drawn path; the run loop is parked in trackDragStep)

class UXSlider : UXControl
    {
    i32 minVal;
    i32 maxVal;
    i32 value;
    i16 knobW;
    void init(void)
        {
        super.init();
        minVal = (i32)0;
        maxVal = (i32)100;
        value = (i32)0;
        knobW = (i16)12;
        }
    // native NSSlider / trackbar; drawRect is the GEM fallback
    UXKind kind(void)
        {
        return UXKindSlider;
        }

    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setPeerOf(index, (pointer)self); // so the driver can build + drive the native control
        }

    // ---- native-control bridge (the driver reads these to build/sync the native control) ------
    i32 nativeMin(void)
        {
        return minVal;
        }
    i32 nativeMax(void)
        {
        return maxVal;
        }
    i32 nativeValue(void)
        {
        return value;
        }
    // the native control moved -> adopt its value
    void applyNativeValue(i32 v)
        {
        self.setValue(v);
        }

    void setRange(i32 lo, i32 hi)
        {
        minVal = lo;
        maxVal = hi > lo ? hi : lo + (i32)1;
        self.clampValue();
        }
    void setValue(i32 v)
        {
        value = v;
        self.clampValue();
        }
    i32 intValue(void)
        {
        return value;
        }
    void clampValue(void)
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

    // knob left-edge x for the current value within a track of width trackW.
    i32 knobX(i16 trackW)
        {
        i32 span = (i32)trackW - (i32)knobW;
        if (span < (i32)0)
            {
            span = (i32)0;
            }
        i32 range = maxVal - minVal;
        return range > (i32)0 ? (value - minVal) * span / range : (i32)0;
        }
    // value for a local x (the click/drag point), centring the knob under the pointer.
    i32 valueForX(i16 lx, i16 trackW)
        {
        i32 span = (i32)trackW - (i32)knobW;
        if (span <= (i32)0)
            {
            return minVal;
            }
        i32 p = (i32)lx - (i32)knobW / (i32)2;
        if (p < (i32)0)
            {
            p = (i32)0;
            }
        if (p > span)
            {
            p = span;
            }
        return minVal + p * (maxVal - minVal) / span;
        }

    void mouseDown(UXEvent* e)
        {
        if (!self.isEnabled())
            {
            return;
            }
        UXRect abs = self.absoluteFrame();
        self.setValue(self.valueForX((i16)((i32)e.x - abs.x), (i16)abs.w));
        self.setNeedsDisplay();
        self.fire();
        // Track the drag so the knob follows the pointer and the value updates live.  Only reached on the
        // self-drawn (GEM) path — native NSSlider/trackbar intercept the mouse and never call mouseDown.
        i32 x = (i32)0;
        i32 y = (i32)0;
        while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
            self.setValue(self.valueForX((i16)((i32)x - abs.x), (i16)abs.w));
            self.setNeedsDisplay();
            self.fire();
            if (gApp != (UXApplication*)0)
                {
                gApp.displayIfNeeded();
                }
            }
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        i16 midY = (i16)(b.h / (i16)2);
        // Themed groove + round knob (Aristo2 on GEM; native NSSlider/trackbar elsewhere skip this).
        g.drawTheme((u8*)"slider.htrack", UXGeom.make((i16)0, (i16)(midY - (i16)2), b.w, (i16)5));
        i16 kx = (i16)self.knobX(b.w);
        g.drawTheme((u8*)"slider.knob", UXGeom.make((i16)(kx - (i16)4), (i16)(midY - (i16)10), (i16)21, (i16)21));
        }
    }
