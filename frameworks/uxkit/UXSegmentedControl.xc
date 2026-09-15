// UXSegmentedControl.xc — a row of selectable segments (NSSegmentedControl in shape).
//
// Equal-width segments laid across the control; a click selects one (single mode, the default) or
// toggles it (multi mode).  It doubles as the tab picker for a tab view.  Layout + hit-test are pure
// geometry and unit-tested without a window; drawing + the absolute->local click ride the UXControl
// seam.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"

class UXSegment : Object
    {
    u8* label;
    i32 tag;
    bool selected;
    i16 x;
    i16 w;
    void init(void)
        {
        label = (u8*)"";
        tag = (i32)0;
        selected = false;
        x = (i16)0;
        w = (i16)0;
        }
    }

    class UXSegmentedControl : UXControl
    {
    Array<UXSegment>* segments;
    bool multiSelect;
    void init(void)
        {
        super.init();
        segments = new Array();
        multiSelect = false;
        }
    // native NSSegmentedControl; drawRect is the GEM fallback
    UXKind kind(void)
        {
        return UXKindSegmented;
        }

    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        t.setPeerOf(index, (pointer)self);
        }

    // ---- native-control bridge -----------------------------------------------
    i32 nativeSegCount(void)
        {
        return self.count();
        }
    u8* nativeSegLabel(i32 i)
        {
        return self.labelAt(i);
        }
    i32 nativeSelectedSeg(void)
        {
        return self.selectedSegment();
        }
    // Win32: CHECKGROUP vs CHECK
    i32 nativeMultiSelect(void)
        {
        return multiSelect ? (i32)1 : (i32)0;
        }
    i32 nativeSegSelected(i32 i)
        {
        return self.isSelected(i) ? (i32)1 : (i32)0;
        }
    void applyNativeSelection(i32 i)
        {
        self.selectSegment(i);
        }

    void addSegment(u8* label, i32 tag)
        {
        UXSegment* s = new UXSegment();
        s.label = label;
        s.tag = tag;
        segments.add(s);
        }
    void setMultiSelect(bool on)
        {
        multiSelect = on;
        }
    i32 count(void)
        {
        return (i32)segments.count();
        }
    UXSegment* segAt(i32 i)
        { return (UXSegment* ?)segments.get((u16)i);
        }
    u8* labelAt(i32 i)
        {
        return self.segAt(i).label;
        }
    i32 tagAt(i32 i)
        {
        return self.segAt(i).tag;
        }
    bool isSelected(i32 i)
        {
        return i >= (i32)0 && i < self.count() && self.segAt(i).selected;
        }
    i32 selectedSegment(void)
        {
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            if (self.segAt(i).selected)
                {
                return i;
                }
            }
        return (i32)-1;
        }

    void layout(i16 width)
        {
        i32 n = self.count();
        if (n == (i32)0)
            {
            return;
            }
        i32 each = (i32)width / n;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXSegment* s = self.segAt(i);
            s.x = (i16)(i * each);
            s.w = (i16)(i == n - (i32)1 ? (i32)width - i * each : each); // last takes the remainder
            }
        }
    i32 segmentAtLocalX(i16 lx)
        {
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            UXSegment* s = self.segAt(i);
            if (lx >= s.x && lx < (i16)(s.x + s.w))
                {
                return i;
                }
            }
        return (i32)-1;
        }

    void selectSegment(i32 i)
        {
        if (i < (i32)0 || i >= self.count())
            {
            return;
            }
        if (multiSelect)
            {
            UXSegment* s = self.segAt(i);
            s.selected = !s.selected;
            }
        else
            {
            for (i32 k = (i32)0; k < self.count(); k = k + (i32)1)
                {
                self.segAt(k).selected = (k == i);
                }
            }
        }

    void mouseDown(UXEvent* e)
        {
        if (!self.isEnabled())
            {
            return;
            }
        UXRect abs = self.absoluteFrame();
        self.layout((i16)abs.w);
        i16 lx = (i16)((i32)e.x - abs.x);
        i32 idx = self.segmentAtLocalX(lx);
        if (idx >= (i32)0)
            {
            self.selectSegment(idx);
            self.setNeedsDisplay();
            self.fire();
            }
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        self.layout(b.w);
        i16 ty = (i16)((b.h - (i16)12) / (i16)2);
        // No dedicated segmented slice in Aristo2, and a segmented control is ONE connected control (not a
        // row of separate buttons): draw a single button bezel across the whole width, hairline dividers
        // between the parts, and fill the picked part with the selection colour.  (GEM only; native
        // NSSegmentedControl / Win32 check-group toolbar elsewhere skip this drawRect.)
        g.drawTheme((u8*)"button", UXGeom.make((i16)0, (i16)0, b.w, b.h));
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            UXSegment* s = self.segAt(i);
            if (s.selected)
                {
                g.fillRect(UXGeom.make((i16)(s.x + (i16)1), (i16)3, (i16)(s.w - (i16)2), (i16)(b.h - (i16)6)), (i32)250);
                }
            // divider
            if (i > (i32)0)
                {
                g.fillRect(UXGeom.make(s.x, (i16)3, (i16)1, (i16)(b.h - (i16)6)), (i32)9);
                }
            g.drawText(s.label, (i16)(s.x + (i16)6), ty, (i32)1, (i32)0);
            }
        }
    }
