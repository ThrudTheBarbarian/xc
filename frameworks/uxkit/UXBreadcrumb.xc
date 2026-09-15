// UXBreadcrumb.xc — a path/navigation breadcrumb widget (general, not just the desktop title bar).
//
// A horizontal row of clickable SEGMENTS ("Home > Documents > Reports") separated by a glyph.  App-
// drawn (kind == UXKindView) so it is identical on GEM / Win32 / AppKit.  When the segments do not fit
// the width it ELIDES the middle — keeps the first segment and as many trailing ones as fit, with an
// ellipsis between — exactly like Finder's path bar.  A click selects a segment and fires the action;
// the app reads selection() (and tagAt) to navigate, the way a table reports its selected row.
//
// The layout (segment rectangles + elision) and hit-testing are pure geometry, so they are unit-
// testable without a window; drawing and the absolute->local click conversion ride on the usual
// UXControl seam.  Text widths are ESTIMATED (charWidth) — a real backend can refine with metrics.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"
#import "Array.xc"

class UXBreadcrumbSegment : Object
    {
    u8* title;
    i32 tag; // app payload (e.g. a node id) reported back on click
    i16 x;
    i16 w;        // laid-out position within the widget
    bool visible; // false when elided into the ellipsis
    void init(void)
        {
        title = (u8*)"";
        tag = (i32)0;
        x = (i16)0;
        w = (i16)0;
        visible = true;
        }
    }

    class UXBreadcrumb : UXControl
    {
    Array<UXBreadcrumbSegment>* segments;
    i16 charWidth; // per-character width estimate
    i16 segPad;    // horizontal padding inside a segment
    i16 sepWidth;  // width taken by the separator glyph + its spacing
    u8* separator; // the glyph drawn between segments
    i32 selectedIndex;
    // elision state (set by layout)
    bool elided;
    bool showEllipsis;
    i16 ellipsisX;
    i16 ellipsisW;

    void init(void)
        {
        super.init();
        segments = new Array();
        charWidth = (i16)7;
        segPad = (i16)6;
        sepWidth = (i16)14;
        separator = (u8*)">";
        selectedIndex = (i32)-1;
        elided = false;
        showEllipsis = false;
        ellipsisX = (i16)0;
        ellipsisW = (i16)0;
        }
    // app-drawn on every backend
    UXKind kind(void)
        {
        return UXKindView;
        }

    // ---- model ---------------------------------------------------------------
    void addSegment(u8* title, i32 tag)
        {
        UXBreadcrumbSegment* s = new UXBreadcrumbSegment();
        s.title = title;
        s.tag = tag;
        segments.add(s);
        }
    void clear(void)
        {
        segments.removeAll();
        selectedIndex = (i32)-1;
        }
    i32 count(void)
        {
        return (i32)segments.count();
        }
    UXBreadcrumbSegment* segAt(i32 i)
        { return (UXBreadcrumbSegment* ?)segments.get((u16)i);
        }
    u8* titleAt(i32 i)
        {
        return self.segAt(i).title;
        }
    i32 tagAt(i32 i)
        {
        return self.segAt(i).tag;
        }
    i32 selection(void)
        {
        return selectedIndex;
        }
    void setSeparator(u8* s)
        {
        separator = s;
        }
    void setCharWidth(i16 w)
        {
        charWidth = w;
        }

    static i32 slen(u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        return n;
        }
    i16 naturalWidth(UXBreadcrumbSegment* s)
        {
        return (i16)((i32)segPad * (i32)2 + (i32)charWidth * UXBreadcrumb.slen(s.title));
        }

    // ---- layout --------------------------------------------------------------
    // Place segments within `width`.  If they all fit (or there are <=2), lay them left to right.
    // Otherwise keep the first + an ellipsis + as many TRAILING segments as fit.
    void layout(i16 width)
        {
        showEllipsis = false;
        elided = false;
        i32 n = self.count();
        if (n == (i32)0)
            {
            return;
            }
        i32 total = (i32)0;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            total = total + (i32)self.naturalWidth(self.segAt(i));
            }
        total = total + (i32)sepWidth * (n - (i32)1);

        // everything fits
        if (total <= (i32)width || n <= (i32)2)
            {
            i16 x = (i16)0;
            for (i32 i = (i32)0; i < n; i = i + (i32)1)
                {
                UXBreadcrumbSegment* s = self.segAt(i);
                s.visible = true;
                s.x = x;
                s.w = self.naturalWidth(s);
                x = (i16)(x + s.w + (i < n - (i32)1 ? sepWidth : (i16)0));
                }
            return;
            }

        // elide the middle
        elided = true;
        showEllipsis = true;
        i16 ellW = (i16)((i32)charWidth * (i32)3 + (i32)segPad); // "..." glyph width estimate
        for (i32 i = (i32)1; i < n; i = i + (i32)1)
            {
            self.segAt(i).visible = false;
            }

        UXBreadcrumbSegment* first = self.segAt((i32)0);
        first.visible = true;
        first.x = (i16)0;
        first.w = self.naturalWidth(first);
        ellipsisX = (i16)(first.w + sepWidth);
        ellipsisW = ellW;

        // fit trailing segments from the end into the remaining width
        i16 avail = (i16)((i32)width - first.w - (i32)sepWidth - ellW - (i32)sepWidth);
        i16 acc = (i16)0;
        i32 j = n - (i32)1;
        while (j >= (i32)1)
            {
            i16 need = (i16)((i32)self.naturalWidth(self.segAt(j)) + (j < n - (i32)1 ? (i32)sepWidth : (i32)0));
            if ((i32)acc + (i32)need > (i32)avail)
                {
                break;
                }
            acc = (i16)(acc + need);
            self.segAt(j).visible = true;
            j = j - (i32)1;
            }
        // place the visible trailing segments after the ellipsis, left to right
        i16 x = (i16)(ellipsisX + ellW + sepWidth);
        for (i32 i = j + (i32)1; i < n; i = i + (i32)1)
            {
            UXBreadcrumbSegment* s = self.segAt(i);
            s.x = x;
            s.w = self.naturalWidth(s);
            x = (i16)(x + s.w + (i < n - (i32)1 ? sepWidth : (i16)0));
            }
        }

    // index of the visible segment whose laid-out box contains local x, else -1.
    i32 segmentAtLocalX(i16 lx)
        {
        for (i32 i = (i32)0; i < self.count(); i = i + (i32)1)
            {
            UXBreadcrumbSegment* s = self.segAt(i);
            if (s.visible && lx >= s.x && lx < (i16)(s.x + s.w))
                {
                return i;
                }
            }
        return (i32)-1;
        }

    // ---- interaction ---------------------------------------------------------
    void mouseDown(UXEvent* e)
        {
        if (!self.isEnabled())
            {
            return;
            }
        UXRect abs = self.absoluteFrame();
        i16 lx = (i16)((i32)e.x - abs.x);
        i32 idx = self.segmentAtLocalX(lx);
        if (idx >= (i32)0)
            {
            selectedIndex = idx;
            self.setNeedsDisplay();
            self.fire();
            }
        }

    // ---- drawing -------------------------------------------------------------
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        self.layout(b.w);
        i32 n = self.count();
        i16 ty = (i16)((b.h - (i16)12) / (i16)2); // rough vertical centring for a 12px glyph
        i32 last = n - (i32)1;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            UXBreadcrumbSegment* s = self.segAt(i);
            if (!s.visible)
                {
                continue;
                }
            // the current (last) location draws darker; ancestors are a lighter "link" grey
            i32 ink = (i == last) ? (i32)1 : (i32)9;
            g.drawText(s.title, (i16)(s.x + segPad), ty, ink, (i32)0);
            // a separator after this segment if something visible follows it
            if (i < last)
                {
                i16 sepx = (i16)(s.x + s.w + (i16)3);
                if (self.showEllipsis && i == (i32)0)
                    {
                    g.drawText(separator, sepx, ty, (i32)9, (i32)0);
                    g.drawText((u8*)"...", ellipsisX, ty, (i32)9, (i32)0);
                    g.drawText(separator, (i16)(ellipsisX + ellipsisW + (i16)3), ty, (i32)9, (i32)0);
                    }
                else
                    {
                    g.drawText(separator, sepx, ty, (i32)9, (i32)0);
                    }
                }
            }
        }
    }
