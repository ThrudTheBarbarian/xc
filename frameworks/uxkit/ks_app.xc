// ks_app.xc — the UXKit kitchen-sink: ONE neutral app, shown on every backend.
//
// This file is driver-agnostic: it names no GEM/Win32/AppKit code, only the neutral toolkit.  The
// thin per-backend mains (ks_mac.xc / ks_win32.xc / ks_a9.xc) choose a driver and run this same
// KitchenSink delegate.  It is meant to GROW — add a widget here and it appears on all three.
//
// What it shows today: labels, a native button set, an editable field, a checkbox, a radio group, a
// multi-selection table, a menu bar + a modal alert, and springs & struts (a corner button that
// stays anchored and a status line that flexes) as the window resizes.
#import <Stdio.xc>
#import "UXApplication.xc"
#import "UXWindow.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXTableView.xc"
#import "UXOutlineView.xc"
#import "UXScrollView.xc"
#import "UXSplitView.xc"
#import "UXSlider.xc"
#import "UXProgressBar.xc"
#import "UXProgress.xc"
#import "UXStepper.xc"
#import "UXPopUpButton.xc"
#import "UXSegmentedControl.xc"
#import "UXToolbar.xc"
#import "UXDragSession.xc"
#import "UXPasteboard.xc"
#import "UXColor.xc"
#import "UXColorPanel.xc"
#import "UXShapePath.xc" // the Vectors window: curves, caps
#import "UXPainter.xc"   // ...stroked and filled through the neutral seam
#import "UXGradient.xc"
#import "UXFont.xc"
#import "UXPredicate.xc"        // the rule engine behind the Rules window
#import "UXTextLayout.xc"       // the line breaker behind the Text window
#import "UXAttributedString.xc" // ...and the rich text it lays out
#import "UXEventRecorder.xc"    // capture + replay, behind the Recorder window
#import "UXOpenPanel.xc"
#import "UXMenu.xc"
#import "UXAlert.xc"
#import "UXString.xc"
#import "UXGeometry.xc"
#import "UXGraphics.xc"
#import "UXEvent.xc"

#define KS_ROWS 8

// A little tree for the outline window — one model, drawn as a native tree on each backend.
class KSNode : Object
    {
    u8* name;
    Array* kids;
    void init(void)
        {
        name = "";
        kids = new Array();
        }
    } KSNode* ksNode(u8* name)
    {
    KSNode* n = new KSNode();
    n.name = name;
    return n;
    }

class KSTree : Object<UXOutlineDataSource>
    {
    KSNode* root;
    void init(void)
        {
        root = (KSNode*)0;
        }
    i32 numberOfChildren(UXOutlineView* o, Object* item)
        {
        KSNode* n = item == (Object*)0 ? root : (KSNode* ?)item;
        return (i32)n.kids.count();
        }
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i)
        {
        KSNode* n = item == (Object*)0 ? root : (KSNode* ?)item;
        return n.kids.get((u16)i);
        }
    bool isExpandable(UXOutlineView* o, Object* item)
        { return ((KSNode* ?)item).kids.count() > (u16)0;
        }
    u8* valueForItem(UXOutlineView* o, Object* item, i32 col)
        { return ((KSNode* ?)item).name;
        }
    }

    // A row of the scroll-view window: a labelled band, alternating shade, so the scroll is obvious.
    class KSCard : UXView
    {
    i32 n;
    void init(void)
        {
        super.init();
        n = (i32)0;
        }
    // factory: keep `new` out of the loop
    static KSCard* make(i32 i)
        {
        KSCard* c = new KSCard();
        c.n = i;
        return c;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, b.h), (n & (i32)1) == (i32)0 ? (i32)0 : (i32)8);
        g.drawText(UXStr.append((u8*)"Item ", UXStr.fromInt(n)), (i16)10, (i16)((b.h - (i16)16) / (i16)2), (i32)1, (i32)16);
        }
    }
    // A pane of the split-view window: a tinted area with a title.
    class KSPane : UXView
    {
    i32 tint;
    u8* name;
    void init(void)
        {
        super.init();
        tint = (i32)8;
        name = (u8*)"";
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, dirty.h), tint);
        g.drawText(name, (i16)10, (i16)12, (i32)1, (i32)16);
        }
    }

    // A backdrop so the widgets sit on a window, and it fills as the window grows (flex width+height).
    class KSCanvas : UXView
    {
    void init(void)
        {
        super.init();
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, dirty.h), (i32)8); // grey backdrop
        g.fillRect(UXGeom.make((i16)0, (i16)0, dirty.w, (i16)6), (i32)2);  // red accent bar
        }
    }

    // ---- an in-app drag-and-drop board -------------------------------------------------------------
    // A drop target: accepts dragged text through the neutral UXDragSession negotiation, and remembers
    // what landed (dragEntered decides the operation; dragPerform consumes the pasteboard).
    class KSWell : Object<UXDragDestination>
    {
    u8* label;
    bool hot;
    void init(void)
        {
        label = (u8*)"drag a tile here";
        hot = false;
        }
    i32 dragEntered(UXDragSession* s)
        {
        return s.hasType((u8*)"public.utf8-plain-text") ? (i32)UX_DRAG_COPY : (i32)UX_DRAG_NONE;
        }
    bool dragPerform(UXDragSession* s)
        {
        u8* t = s.stringForType((u8*)"public.utf8-plain-text");
        if (t == (u8*)0)
            {
            return false;
            }
        label = UXStr.append((u8*)"dropped: ", t);
        return true;
        }
    }

    // Three labelled tiles you can pick up and drag onto the well.  The drag is live: trackDragStep pulls
    // the pointer, a ghost tile follows it, the well lights up while a valid drag hovers (negotiated via
    // UXDragSession.enter), and the drop delivers the tile's text to the well.  This is in-app drag/drop —
    // one process, so no OS protocol involved; the same UXDragSession is what a system bridge would drive.
    class KSDragBoard : UXView
    {
    KSWell* well;
    i32 dragIdx; // which tile is in hand (-1 = none)
    i16 dragX;
    i16 dragY; // pointer, view-local, during a drag
    void init(void)
        {
        super.init();
        well = new KSWell();
        dragIdx = (i32)-1;
        dragX = (i16)0;
        dragY = (i16)0;
        }

    u8* tileLabel(i32 i)
        {
        if (i == (i32)0)
            {
            return (u8*)"Report";
            }
        if (i == (i32)1)
            {
            return (u8*)"Photo";
            }
        return (u8*)"Notes";
        }
    UXRect tileHome(i32 i)
        {
        return UXGeom.make((i16)12, (i16)(12 + i * (i32)36), (i16)92, (i16)30);
        }
    UXRect wellRect(void)
        {
        UXRect b = self.bounds();
        return UXGeom.make((i16)122, (i16)12, (i16)((i32)b.w - (i32)134), (i16)((i32)b.h - (i32)24));
        }
    bool inRect(UXRect r, i16 x, i16 y)
        {
        return x >= r.x && x < (i16)(r.x + r.w) && y >= r.y && y < (i16)(r.y + r.h);
        }
    i32 tileAt(i16 x, i16 y)
        {
        for (i32 i = (i32)0; i < (i32)3; i = i + (i32)1)
            {
            if (self.inRect(self.tileHome(i), x, y))
                {
                return i;
                }
            }
        return (i32)-1;
        }

    void drawTile(UXGraphics* g, UXRect r, u8* label)
        {
        g.drawTheme((u8*)"button", r);
        g.drawText(label, (i16)(r.x + (i16)10), (i16)(r.y + (i16)((i32)r.h - (i32)12) / (i32)2), (i32)1, (i32)0);
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)8); // grey backdrop
        // source tiles (home)
        for (i32 i = (i32)0; i < (i32)3; i = i + (i32)1)
            {
            if (i != dragIdx)
                {
                self.drawTile(g, self.tileHome(i), self.tileLabel(i));
                }
            }
        UXRect w = self.wellRect();                  // the drop well
        g.fillRect(w, well.hot ? (i32)250 : (i32)0); // lit while a valid drag hovers
        g.fillRect(UXGeom.make(w.x, w.y, w.w, (i16)1), (i32)9);
        g.fillRect(UXGeom.make(w.x, (i16)(w.y + w.h - (i16)1), w.w, (i16)1), (i32)9);
        g.fillRect(UXGeom.make(w.x, w.y, (i16)1, w.h), (i32)9);
        g.fillRect(UXGeom.make((i16)(w.x + w.w - (i16)1), w.y, (i16)1, w.h), (i32)9);
        g.drawText(well.label, (i16)(w.x + (i16)10), (i16)(w.y + (i16)12), (i32)1, (i32)0);
        // the ghost tile in hand
        if (dragIdx >= (i32)0)
            {
            self.drawTile(g, UXGeom.make((i16)(dragX - (i16)46), (i16)(dragY - (i16)15), (i16)92, (i16)30), self.tileLabel(dragIdx));
            }
        }
    void mouseDown(UXEvent* e)
        {
        UXRect abs = self.absoluteFrame();
        i32 hit = self.tileAt((i16)((i32)e.x - abs.x), (i16)((i32)e.y - abs.y));
        if (hit < (i32)0)
            {
            return;
            }
        UXPasteboard* pb = new UXPasteboard();
        pb.writeText(self.tileLabel(hit));
        UXDragSession* s = UXDragSession.begin((Object*)self, pb, (i32)UX_DRAG_COPY);
        dragIdx = hit;
        i32 x = (i32)e.x;
        i32 y = (i32)e.y;
        // live-track the pointer
        while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
            dragX = (i16)((i32)x - abs.x);
            dragY = (i16)((i32)y - abs.y);
            well.hot = self.inRect(self.wellRect(), dragX, dragY) && (s.enter(well) != (i32)UX_DRAG_NONE);
            self.setNeedsDisplay();
            if (gApp != (UXApplication*)0)
                {
                gApp.displayIfNeeded();
                }
            }
        // drop
        if (self.inRect(self.wellRect(), dragX, dragY))
            {
            s.enter(well);
            if (s.canDrop())
                {
                s.deliver(well);
                }
            }
        well.hot = false;
        dragIdx = (i32)-1;
        self.setNeedsDisplay();
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    }

// ---- Colour selection + an image well --------------------------------------------------------------
// GEM is true-colour (32-bit RGBA) on this platform, so this is a real NSColorPanel-style picker: a
// hue/saturation colour WHEEL (drawn at the current brightness), HSV and RGB slider rows with live
// gradient tracks, a preview, and an image well painted with the chosen colour.  Every swatch/track/
// pixel is drawn with UXGraphics.fillRectRGB (v_setrgb under the hood on GEM).
#define CW_X 18 // colour-wheel child view: origin, size, centre, radius
#define CW_Y 26
#define CW_SZ 180
#define CW_C 90 // centre within the wheel view
#define CW_R 84
#define CS_LBLX 212 // slider label / value columns (drawn by the board)
#define CS_TRKX 240 // slider child views: x, width, height
#define CS_TRKW 178
#define CS_VALX 424
#define CS_TRKH 16

    // Integer trig + sqrt (no libm): a 5-degree sine table (x1000) with symmetry, and Newton's isqrt.
    class KSMath
    {
    static i32 sinTbl(i32 i)
        {
        if (i <= (i32)0)
            {
            return (i32)0;
            }
        if (i == (i32)1)
            {
            return (i32)87;
            }
        if (i == (i32)2)
            {
            return (i32)174;
            }
        if (i == (i32)3)
            {
            return (i32)259;
            }
        if (i == (i32)4)
            {
            return (i32)342;
            }
        if (i == (i32)5)
            {
            return (i32)423;
            }
        if (i == (i32)6)
            {
            return (i32)500;
            }
        if (i == (i32)7)
            {
            return (i32)574;
            }
        if (i == (i32)8)
            {
            return (i32)643;
            }
        if (i == (i32)9)
            {
            return (i32)707;
            }
        if (i == (i32)10)
            {
            return (i32)766;
            }
        if (i == (i32)11)
            {
            return (i32)819;
            }
        if (i == (i32)12)
            {
            return (i32)866;
            }
        if (i == (i32)13)
            {
            return (i32)906;
            }
        if (i == (i32)14)
            {
            return (i32)940;
            }
        if (i == (i32)15)
            {
            return (i32)966;
            }
        if (i == (i32)16)
            {
            return (i32)985;
            }
        if (i == (i32)17)
            {
            return (i32)996;
            }
        return (i32)1000;
        }
    static i32 sin0_90(i32 d)
        {
        if (d >= (i32)90)
            {
            return (i32)1000;
            }
        i32 i = d / (i32)5;
        i32 f = d % (i32)5;
        i32 lo = KSMath.sinTbl(i);
        return lo + (KSMath.sinTbl(i + (i32)1) - lo) * f / (i32)5;
        }
    static i32 sinDeg(i32 d)
        {
        d = ((d % (i32)360) + (i32)360) % (i32)360;
        if (d <= (i32)90)
            {
            return KSMath.sin0_90(d);
            }
        if (d <= (i32)180)
            {
            return KSMath.sin0_90((i32)180 - d);
            }
        if (d <= (i32)270)
            {
            return -KSMath.sin0_90(d - (i32)180);
            }
        return -KSMath.sin0_90((i32)360 - d);
        }
    static i32 cosDeg(i32 d)
        {
        return KSMath.sinDeg(d + (i32)90);
        }
    // Integer sqrt, bit-by-bit (no division loop that could hang) — floor(sqrt(n)).
    static i32 isqrt(i32 n)
        {
        if (n <= (i32)0)
            {
            return (i32)0;
            }
        i32 bit = (i32)1073741824; // 4^15, above any r^2 we feed it
        while (bit > n)
            {
            bit = bit / (i32)4;
            }
        i32 r = (i32)0;
        while (bit != (i32)0)
            {
            if (n >= r + bit)
                {
                n = n - (r + bit);
                r = r / (i32)2 + bit;
                }
            else
                {
                r = r / (i32)2;
                }
            bit = bit / (i32)4;
            }
        return r;
        }
    // The hue (0..359) whose unit vector best aligns with (dx,dy) — same convention the wheel is drawn in.
    static i32 hueForDir(i32 dx, i32 dy)
        {
        i32 best = (i32)0;
        i32 bestDot = (i32)-2147483647;
        for (i32 h = (i32)0; h < (i32)360; h = h + (i32)1)
            {
            i32 dot = KSMath.cosDeg(h) * dx + KSMath.sinDeg(h) * dy;
            if (dot > bestDot)
                {
                bestDot = dot;
                best = h;
                }
            }
        return best;
        }
    // atan(i/10) in degrees, i = 0..10
    static i32 atanTbl(i32 i)
        {
        if (i <= (i32)0)
            {
            return (i32)0;
            }
        if (i == (i32)1)
            {
            return (i32)6;
            }
        if (i == (i32)2)
            {
            return (i32)11;
            }
        if (i == (i32)3)
            {
            return (i32)17;
            }
        if (i == (i32)4)
            {
            return (i32)22;
            }
        if (i == (i32)5)
            {
            return (i32)27;
            }
        if (i == (i32)6)
            {
            return (i32)31;
            }
        if (i == (i32)7)
            {
            return (i32)35;
            }
        if (i == (i32)8)
            {
            return (i32)39;
            }
        if (i == (i32)9)
            {
            return (i32)42;
            }
        return (i32)45;
        }
    // atan(num/den), 0<=num<=den, result 0..45
    static i32 atanFrac(i32 num, i32 den)
        {
        if (den <= (i32)0)
            {
            return (i32)0;
            }
        i32 idx = num * (i32)10 / den;
        if (idx >= (i32)10)
            {
            return (i32)45;
            }
        i32 lo = KSMath.atanTbl(idx);
        i32 rem = num * (i32)10 - idx * den;
        return lo + (KSMath.atanTbl(idx + (i32)1) - lo) * rem / den;
        }
    // atan2 in degrees 0..359, x right / y DOWN (screen), matching cosDeg/sinDeg placement.
    static i32 atan2deg(i32 y, i32 x)
        {
        if (x == (i32)0 && y == (i32)0)
            {
            return (i32)0;
            }
        i32 ax = x < (i32)0 ? -x : x;
        i32 ay = y < (i32)0 ? -y : y;
        i32 a = ax >= ay ? KSMath.atanFrac(ay, ax) : (i32)90 - KSMath.atanFrac(ax, ay);
        i32 deg;
        if (x >= (i32)0 && y >= (i32)0)
            {
            deg = a;
            }
        else if (x < (i32)0 && y >= (i32)0)
            {
            deg = (i32)180 - a;
            }
        else if (x < (i32)0 && y < (i32)0)
            {
            deg = (i32)180 + a;
            }
        else
            {
            deg = (i32)360 - a;
            }
        return ((deg % (i32)360) + (i32)360) % (i32)360;
        }
    }

    // The hue/saturation colour wheel as its own view — drawn per-pixel (gap-free) at the current
    // brightness, with a marker; a click/drag drives the shared model on the board.
    class KSColorWheel : UXView
    {
    weak : KSColourBoard* board;
    void init(void)
        {
        super.init();
        board = (KSColourBoard*)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    void ring(UXGraphics* g, UXRect r, i32 pen)
        {
        g.drawLine(r.x, r.y, (i16)(r.x + r.w), r.y, pen);
        g.drawLine(r.x, (i16)(r.y + r.h), (i16)(r.x + r.w), (i16)(r.y + r.h), pen);
        g.drawLine(r.x, r.y, r.x, (i16)(r.y + r.h), pen);
        g.drawLine((i16)(r.x + r.w), r.y, (i16)(r.x + r.w), (i16)(r.y + r.h), pen);
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)8); // grey corners
        if (board == (KSColourBoard*)0)
            {
            return;
            }
        i32 V = board.brightness();
        i32 over = (i32)CW_R + (i32)1; // overfill past the rim; the border covers it
        for (i32 y = (i32)0; y < (i32)CW_SZ; y = y + (i32)3)
            {
            for (i32 x = (i32)0; x < (i32)CW_SZ; x = x + (i32)3)
                {
                i32 dx = x - (i32)CW_C;
                i32 dy = y - (i32)CW_C;
                i32 r2 = dx * dx + dy * dy;
                if (r2 <= over * over)
                    {
                    i32 r = KSMath.isqrt(r2);
                    UXColor* c = UXColor.hsb(KSMath.atan2deg(dy, dx), r * (i32)255 / (i32)CW_R, V);
                    g.fillRectRGB(UXGeom.make((i16)x, (i16)y, (i16)3, (i16)3), c.r, c.g, c.b);
                    }
                }
            }
        // a thick, ANTI-ALIASED black rim: per-pixel over the edge band, fully black in the middle, the
        // inner edge blended into the wheel colour and the outer edge into the grey — no facets, no jaggies.
        i32 Ri = (i32)CW_R;
        i32 Ro = (i32)CW_R + (i32)5;
        i32 lo = (Ri - (i32)1) * (Ri - (i32)1);
        i32 hi = (Ro + (i32)1) * (Ro + (i32)1);
        for (i32 y = (i32)CW_C - Ro - (i32)1; y <= (i32)CW_C + Ro + (i32)1; y = y + (i32)1)
            {
            for (i32 x = (i32)CW_C - Ro - (i32)1; x <= (i32)CW_C + Ro + (i32)1; x = x + (i32)1)
                {
                i32 dx = x - (i32)CW_C;
                i32 dy = y - (i32)CW_C;
                i32 r2 = dx * dx + dy * dy;
                if (r2 < lo || r2 > hi)
                    {
                    continue;
                    }
                i32 r16 = KSMath.isqrt(r2 * (i32)256); // r * 16 (sub-pixel)
                if (r16 >= Ri * (i32)16 && r16 <= Ro * (i32)16)
                    {
                    g.fillRectRGB(UXGeom.make((i16)x, (i16)y, (i16)1, (i16)1), (i32)0, (i32)0, (i32)0);
                    }
                // inner AA: wheel colour -> black
                else if (r16 < Ri * (i32)16)
                    {
                    i32 cov = r16 - (Ri - (i32)1) * (i32)16;
                    if (cov < (i32)0)
                        {
                        cov = (i32)0;
                        }
                    if (cov > (i32)16)
                        {
                        cov = (i32)16;
                        }
                    i32 k = (i32)16 - cov;
                    i32 r = r16 / (i32)16;
                    UXColor* c = UXColor.hsb(KSMath.atan2deg(dy, dx), r * (i32)255 / (i32)CW_R, V);
                    g.fillRectRGB(UXGeom.make((i16)x, (i16)y, (i16)1, (i16)1), c.r * k / (i32)16, c.g * k / (i32)16, c.b * k / (i32)16);
                    }
                // outer AA: black -> grey (192)
                else
                    {
                    i32 cov = (Ro + (i32)1) * (i32)16 - r16;
                    if (cov < (i32)0)
                        {
                        cov = (i32)0;
                        }
                    if (cov > (i32)16)
                        {
                        cov = (i32)16;
                        }
                    i32 gr = (i32)192 * ((i32)16 - cov) / (i32)16;
                    g.fillRectRGB(UXGeom.make((i16)x, (i16)y, (i16)1, (i16)1), gr, gr, gr);
                    }
                }
            }
        // the hue/sat marker, on top so it stays visible even at the rim
        i32 mr = board.sat() * (i32)(CW_R - (i32)2) / (i32)255;
        i16 mx = (i16)((i32)CW_C + KSMath.cosDeg(board.hue()) * mr / (i32)1000);
        i16 my = (i16)((i32)CW_C + KSMath.sinDeg(board.hue()) * mr / (i32)1000);
        self.ring(g, UXGeom.make((i16)(mx - (i16)4), (i16)(my - (i16)4), (i16)8, (i16)8), (i32)0);
        self.ring(g, UXGeom.make((i16)(mx - (i16)3), (i16)(my - (i16)3), (i16)6, (i16)6), (i32)1);
        }
    void mouseDown(UXEvent* e)
        {
        if (board == (KSColourBoard*)0)
            {
            return;
            }
        UXRect abs = self.absoluteFrame();
        board.pickWheel((i16)((i32)e.x - abs.x), (i16)((i32)e.y - abs.y));
        i32 x = (i32)0;
        i32 y = (i32)0;
        while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
            board.pickWheel((i16)((i32)x - abs.x), (i16)((i32)y - abs.y));
            }
        }
    }

    // One HSV/RGB slider: a real UXSlider (so the drag "just works" like the Widgets slider) that paints a
    // live colour-gradient track instead of the themed groove.  comp 0..5 = H,S,V,R,G,B.
    class KSColorSlider : UXSlider
    {
    weak : KSColourBoard* board;
    i32 comp;
    void init(void)
        {
        super.init();
        board = (KSColourBoard*)0;
        comp = (i32)0;
        knobW = (i16)8;
        }
    // Factory: keeps `new` out of setup()'s loop (the slider is kept by the board's array + the view tree).
    static KSColorSlider* make(KSColourBoard* b, i32 c)
        {
        KSColorSlider* s = new KSColorSlider();
        s.board = b;
        s.comp = c;
        return s;
        }
    // app-drawn (gradient) + mouseDown drag on every backend
    UXKind kind(void)
        {
        return UXKindView;
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        if (board != (KSColourBoard*)0)
            {
            for (i32 x = (i32)0; x < (i32)b.w; x = x + (i32)2)
                {
                UXColor* c = board.compColorAt(comp, x * (i32)1000 / (i32)b.w);
                g.fillRectRGB(UXGeom.make((i16)x, (i16)0, (i16)2, b.h), c.r, c.g, c.b);
                }
            }
        g.drawLine((i16)0, (i16)0, (i16)(b.w - (i16)1), (i16)0, (i32)1);
        g.drawLine((i16)0, (i16)(b.h - (i16)1), (i16)(b.w - (i16)1), (i16)(b.h - (i16)1), (i32)1);
        g.drawLine((i16)0, (i16)0, (i16)0, (i16)(b.h - (i16)1), (i32)1);
        g.drawLine((i16)(b.w - (i16)1), (i16)0, (i16)(b.w - (i16)1), (i16)(b.h - (i16)1), (i32)1);
        i16 kx = (i16)((i32)self.knobX(b.w) + (i32)knobW / (i32)2);
        g.fillRect(UXGeom.make((i16)(kx - (i16)2), (i16)(-2), (i16)4, (i16)(b.h + (i16)4)), (i32)1);
        g.fillRect(UXGeom.make(kx, (i16)(-1), (i16)1, (i16)(b.h + (i16)2)), (i32)0);
        }
    }

    // The GEM toolkit colour picker: a hue/sat wheel + HSV/RGB sliders + a preview.  (On backends with an OS
    // picker this is never built — the driver's native NSColorPanel is presented instead.)
    class KSColourBoard : UXView
    {
    UXColorPanel* pick; // the HSV picking model (hue/sat/bri), shared by wheel + sliders
    KSColorWheel* wheel;
    Array<KSColorSlider>* sliders; // 6 KSColorSlider (H,S,V,R,G,B)
    void init(void)
        {
        super.init();
        pick = new UXColorPanel();
        pick.setColor(UXColor.rgb((i32)64, (i32)150, (i32)220));
        wheel = (KSColorWheel*)0;
        sliders = new Array();
        }
    // adopt an externally-set colour
    void setColor(UXColor* c)
        {
        pick.setColor(c);
        self.modelChanged();
        }
    // set the model before setup() builds the controls
    void seed(UXColor* c)
        {
        pick.setColor(c);
        }
    static u8 hxd(i32 n)
        {
        return n < (i32)10 ? (u8)((i32)48 + n) : (u8)((i32)55 + n);
        }
    // "#RRGGBB" (caller owns the malloc)
    static u8* hexStr(UXColor* c)
        {
        u8* o = (u8*)malloc((u32)8);
        o[(i32)0] = (u8)35;
        o[(i32)1] = KSColourBoard.hxd(c.r / (i32)16);
        o[(i32)2] = KSColourBoard.hxd(c.r % (i32)16);
        o[(i32)3] = KSColourBoard.hxd(c.g / (i32)16);
        o[(i32)4] = KSColourBoard.hxd(c.g % (i32)16);
        o[(i32)5] = KSColourBoard.hxd(c.b / (i32)16);
        o[(i32)6] = KSColourBoard.hxd(c.b % (i32)16);
        o[(i32)7] = (u8)0;
        return o;
        }
    // Build the wheel + sliders as sibling views ON the canvas, over this board (each owns its own input).
    // Siblings (not children) — a big self-drawn view with its own subviews doesn't realise cleanly, but
    // as siblings drawn after the board they layer correctly and hit-test to themselves.
    void setup(UXView* canvas)
        {
        wheel = new KSColorWheel();
        wheel.board = self;
        canvas.addSubview(wheel, UXGeom.make((i16)CW_X, (i16)CW_Y, (i16)CW_SZ, (i16)CW_SZ));
        for (i32 i = (i32)0; i < (i32)6; i = i + (i32)1)
            {
            KSColorSlider* s = KSColorSlider.make(self, i);
            s.setRange((i32)0, self.compMax(i));
            s.setValue(self.compValue(i));
            s.setAction(&self.onSlider);
            canvas.addSubview(s, UXGeom.make((i16)CS_TRKX, self.rowY(i), (i16)CS_TRKW, (i16)CS_TRKH));
            sliders.add(s);
            }
        }
    void redraw(void)
        {
        self.setNeedsDisplay();
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    UXColor* curColor(void)
        {
        return pick.color();
        }
    i32 brightness(void)
        {
        return pick.brightnessValue();
        }
    i32 hue(void)
        {
        return pick.hueValue();
        }
    i32 sat(void)
        {
        return pick.saturationValue();
        }

    // ---- geometry ----
    // HSV rows, gap, RGB rows
    i16 rowY(i32 i)
        {
        return (i16)(i < (i32)3 ? (i32)32 + i * (i32)28 : (i32)124 + (i - (i32)3) * (i32)28);
        }
    UXRect previewRect(void)
        {
        return UXGeom.make((i16)18, (i16)(CW_Y + CW_SZ + (i16)10), (i16)180, (i16)30);
        }

    // ---- the six colour components: comp 0..5 = H,S,V,R,G,B ----
    u8* compLabel(i32 k)
        {
        if (k == (i32)0)
            {
            return (u8*)"H";
            }
        if (k == (i32)1)
            {
            return (u8*)"S";
            }
        if (k == (i32)2)
            {
            return (u8*)"V";
            }
        if (k == (i32)3)
            {
            return (u8*)"R";
            }
        if (k == (i32)4)
            {
            return (u8*)"G";
            }
        return (u8*)"B";
        }
    i32 compMax(i32 k)
        {
        return k == (i32)0 ? (i32)359 : (i32)255;
        }
    i32 compValue(i32 k)
        {
        UXColor* c = self.curColor();
        if (k == (i32)0)
            {
            return pick.hueValue();
            }
        if (k == (i32)1)
            {
            return pick.saturationValue();
            }
        if (k == (i32)2)
            {
            return pick.brightnessValue();
            }
        if (k == (i32)3)
            {
            return c.r;
            }
        if (k == (i32)4)
            {
            return c.g;
            }
        return c.b;
        }
    // The colour shown at fraction f (0..1000) of component k's slider track.
    UXColor* compColorAt(i32 k, i32 f)
        {
        UXColor* c = self.curColor();
        if (k == (i32)0)
            {
            return UXColor.hsb(f * (i32)359 / (i32)1000, (i32)255, (i32)255);
            }
        if (k == (i32)1)
            {
            return UXColor.hsb(pick.hueValue(), f * (i32)255 / (i32)1000, pick.brightnessValue());
            }
        if (k == (i32)2)
            {
            return UXColor.hsb(pick.hueValue(), pick.saturationValue(), f * (i32)255 / (i32)1000);
            }
        if (k == (i32)3)
            {
            return UXColor.rgb(f * (i32)255 / (i32)1000, c.g, c.b);
            }
        if (k == (i32)4)
            {
            return UXColor.rgb(c.r, f * (i32)255 / (i32)1000, c.b);
            }
        return UXColor.rgb(c.r, c.g, f * (i32)255 / (i32)1000);
        }
    // Adopt a component's new value (v is already in the component's own units).
    void setComp(i32 k, i32 v)
        {
        UXColor* c = self.curColor();
        if (k == (i32)0)
            {
            pick.setHue(v);
            }
        else if (k == (i32)1)
            {
            pick.setSaturation(v);
            }
        else if (k == (i32)2)
            {
            pick.setBrightness(v);
            }
        else if (k == (i32)3)
            {
            pick.setColor(UXColor.rgb(v, c.g, c.b));
            }
        else if (k == (i32)4)
            {
            pick.setColor(UXColor.rgb(c.r, v, c.b));
            }
        else
            {
            pick.setColor(UXColor.rgb(c.r, c.g, v));
            }
        }
    // A slider moved: adopt its value, then push the model back out to every control + repaint.
    void onSlider(UXControl* c)
        {
        KSColorSlider* s = (KSColorSlider* ?)c;
        if (s == (KSColorSlider*)0)
            {
            return;
            }
        self.setComp(s.comp, s.intValue());
        self.modelChanged();
        }
    // Sync every control to the model, then repaint live (self-drawn drag path).
    void modelChanged(void)
        {
        for (u16 i = (u16)0; i < sliders.count(); i = i + (u16)1)
            {
            KSColorSlider* s = (KSColorSlider* ?)sliders.get(i);
            s.setValue(self.compValue(s.comp));
            s.setNeedsDisplay();
            }
        if (wheel != (KSColorWheel*)0)
            {
            wheel.setNeedsDisplay();
            }
        self.setNeedsDisplay();
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }

    // ---- drawing ----
    void frame(UXGraphics* g, UXRect r, i32 pen)
        {
        g.drawLine(r.x, r.y, (i16)(r.x + r.w), r.y, pen);
        g.drawLine(r.x, (i16)(r.y + r.h), (i16)(r.x + r.w), (i16)(r.y + r.h), pen);
        g.drawLine(r.x, r.y, r.x, (i16)(r.y + r.h), pen);
        g.drawLine((i16)(r.x + r.w), r.y, (i16)(r.x + r.w), (i16)(r.y + r.h), pen);
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)8); // grey backdrop
        g.drawText((u8*)"Colour wheel", (i16)20, (i16)12, (i32)1, (i32)0);
        g.drawText((u8*)"HSV", (i16)CS_LBLX, (i16)14, (i32)1, (i32)0);
        g.drawText((u8*)"RGB", (i16)CS_LBLX, (i16)108, (i32)1, (i32)0);
        // the wheel + slider TRACKS are child views; the board only labels the rows + shows the values
        for (i32 k = (i32)0; k < (i32)6; k = k + (i32)1)
            {
            i16 y = self.rowY(k);
            g.drawText(self.compLabel(k), (i16)CS_LBLX, (i16)(y + (i16)2), (i32)1, (i32)0);
            g.drawText(UXStr.fromInt(self.compValue(k)), (i16)CS_VALX, (i16)(y + (i16)2), (i32)1, (i32)0);
            }
        // preview swatch + hex readout
        UXColor* cur = self.curColor();
        UXRect pv = self.previewRect();
        g.fillRectRGB(pv, cur.r, cur.g, cur.b);
        self.frame(g, pv, (i32)1);
        u8 hx[10];
        self.hex6(cur, (u8*)&hx[0]);
        g.drawText(UXStr.append(UXStr.append(UXStr.append(UXStr.append((u8*)"RGB ", UXStr.fromInt(cur.r)), UXStr.append((u8*)",", UXStr.fromInt(cur.g))), UXStr.append((u8*)",", UXStr.fromInt(cur.b))), UXStr.append((u8*)"   #", (u8*)&hx[0])), (i16)20, (i16)(pv.y + pv.h + (i16)8), (i32)1, (i32)0);
        }
    void hex6(UXColor* c, u8* out)
        {
        self.hex2(c.r, out);
        self.hex2(c.g, (u8*)&out[(i32)2]);
        self.hex2(c.b, (u8*)&out[(i32)4]);
        out[(i32)6] = (u8)0;
        }
    void hex2(i32 v, u8* out)
        {
        out[(i32)0] = self.hexd(v / (i32)16);
        out[(i32)1] = self.hexd(v % (i32)16);
        }
    u8 hexd(i32 n)
        {
        return n < (i32)10 ? (u8)((i32)48 + n) : (u8)((i32)55 + n);
        }

    // Set hue+saturation from a point in the wheel view (its local coords), then sync everything.
    void pickWheel(i16 lx, i16 ly)
        {
        i32 dx = (i32)lx - (i32)CW_C;
        i32 dy = (i32)ly - (i32)CW_C;
        i32 r = KSMath.isqrt(dx * dx + dy * dy);
        if (r > (i32)CW_R)
            {
            r = (i32)CW_R;
            }
        pick.setSaturation(r * (i32)255 / (i32)CW_R);
        if (r > (i32)0)
            {
            pick.setHue(KSMath.atan2deg(dy, dx));
            }
        self.modelChanged();
        }
    }

// ---------------------------------------------------------------------------
// The GEM/Win32 toolkit font chooser: a family list + size stepper + bold/italic
// + a live preview.  (On macOS the driver presents the native NSFontPanel instead,
// so this is never built there.)  Scope is "chooser + native preview": the toolkit
// can only vary the drawn *size*, so the preview shows the sample at the chosen size
// and names the family/style in text — matching what drawText can actually render.
#define KF_ROWH 22
#define KF_MAXFAM 40

    // The chooser's family list, cached from the driver at setup (each name is a heap dup).  A global,
    // like the table's ksName[] — the chooser is effectively a singleton (one Font window at a time).
    u8* ksFamName[KF_MAXFAM];
i32 ksFamCount;

// The family list: a self-drawn, click-to-select column living inside an UXScrollView, so it scrolls
// when there are more families than fit (the document is familyCount * KF_ROWH tall).
class KSFontListView : UXView
    {
    weak : KSFontBoard* board;
    void init(void)
        {
        super.init();
        board = (KSFontBoard*)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    void border(UXGraphics* g, UXRect b)
        {
        g.drawLine((i16)0, (i16)0, (i16)(b.w - (i16)1), (i16)0, (i32)1);
        g.drawLine((i16)0, (i16)(b.h - (i16)1), (i16)(b.w - (i16)1), (i16)(b.h - (i16)1), (i32)1);
        g.drawLine((i16)0, (i16)0, (i16)0, (i16)(b.h - (i16)1), (i32)1);
        g.drawLine((i16)(b.w - (i16)1), (i16)0, (i16)(b.w - (i16)1), (i16)(b.h - (i16)1), (i32)1);
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)0); // white
        if (board == (KSFontBoard*)0)
            {
            self.border(g, b);
            return;
            }
        i32 n = board.familyCount();
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            i16 ry = (i16)(i * (i32)KF_ROWH);
            if (i == board.selFamily)
                {
                g.fillRectRGB(UXGeom.make((i16)1, (i16)(ry + (i16)1), (i16)(b.w - (i16)2), (i16)(KF_ROWH - (i16)1)), (i32)64, (i32)120, (i32)200);
                g.drawText(board.familyAt(i), (i16)8, (i16)(ry + (i16)5), (i32)0, (i32)0); // white text on the highlight
                }
            else
                {
                g.drawText(board.familyAt(i), (i16)8, (i16)(ry + (i16)5), (i32)1, (i32)0); // black
                }
            }
        self.border(g, b);
        }
    // Just the one row's strip — a selection moving damages two rows, not 200x198 of list.
    void dirtyRow(i32 i)
        {
        if (i < (i32)0)
            {
            return;
            }
        UXRect a = self.absoluteFrame();
        self.setNeedsDisplayInRect(UXGeom.make(a.x, (i16)(a.y + i * (i32)KF_ROWH), a.w, (i16)KF_ROWH));
        }
    void mouseDown(UXEvent* e)
        {
        if (board == (KSFontBoard*)0)
            {
            return;
            }
        UXRect abs = self.absoluteFrame();
        i32 row = ((i32)e.y - abs.y) / (i32)KF_ROWH;
        if (row >= (i32)0 && row < board.familyCount())
            {
            board.selectFamily(row);
            }
        }
    }

    class KSFontBoard : UXView
    {
    UXFont* fdesc; // the descriptor being edited (seeded from, and reported back to, pickedFont)
    i32 selFamily; // highlighted row in the family list
    KSFontListView* list;
    UXStepper* sizeStepper;
    UXCheckbox* boldBox;
    UXCheckbox* italicBox;
    void init(void)
        {
        super.init();
        fdesc = UXFont.makeTraits((u8*)"System", (i16)18, false, false);
        selFamily = (i32)0;
        list = (KSFontListView*)0;
        sizeStepper = (UXStepper*)0;
        boldBox = (UXCheckbox*)0;
        italicBox = (UXCheckbox*)0;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }
    // selFamily is resolved in loadFamilies()
    void seed(UXFont* f)
        {
        fdesc = f.dup();
        }
    UXFont* curFont(void)
        {
        return fdesc;
        }

    // The family list, enumerated from the driver (GEM: its real loaded faces; Win32/Cocoa: a curated set).
    i32 familyCount(void)
        {
        return ksFamCount;
        }
    u8* familyAt(i32 i)
        {
        return (i >= (i32)0 && i < ksFamCount) ? ksFamName[i] : (u8*)"";
        }
    i32 familyIndex(u8* fam)
        {
        for (i32 i = (i32)0; i < ksFamCount; i = i + (i32)1)
            {
            if (UXFont.streq(ksFamName[i], fam))
                {
                return i;
                }
            }
        return (i32)-1;
        }
    // Pull the driver's family names into the cache, then point the seeded descriptor at a real entry.
    void loadFamilies(void)
        {
        i32 n = gDriver.fontFamilyCount();
        if (n > (i32)KF_MAXFAM)
            {
            n = (i32)KF_MAXFAM;
            }
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            u8 buf[96];
            if (gDriver.fontFamilyName(i, (u8*)&buf[0], (i32)96) < (i32)0)
                {
                buf[(i32)0] = (u8)0;
                }
            ksFamName[i] = UXStr.append((u8*)"", (u8*)&buf[0]); // heap dup of the driver's name
            }
        ksFamCount = n;
        i32 idx = self.familyIndex(fdesc.family); // seed didn't match a real face?
        if (idx < (i32)0)
            {
            idx = (i32)0;
            if (ksFamCount > (i32)0)
                {
                fdesc.family = ksFamName[(i32)0];
                }
            }
        selFamily = idx;
        }

    void setup(UXView* canvas)
        {
        self.loadFamilies();
        // The family column lives inside a scroll view so >N families scroll (document = count * KF_ROWH).
        UXScrollView* sv = new UXScrollView();
        canvas.addSubview(sv, UXGeom.make((i16)18, (i16)30, (i16)200, (i16)168));
        sv.setLineHeight((i16)KF_ROWH);
        UXView* doc = sv.document();
        list = new KSFontListView();
        list.board = self;
        i32 fullH = ksFamCount * (i32)KF_ROWH;
        if (fullH < (i32)168)
            {
            fullH = (i32)168;
            }
        doc.addSubview(list, UXGeom.make((i16)0, (i16)0, (i16)184, (i16)fullH));
        sv.setDocumentHeight(fullH);
        sizeStepper = new UXStepper();
        sizeStepper.setRange((i32)6, (i32)72);
        sizeStepper.setValue((i32)fdesc.size);
        sizeStepper.setAction(&self.onSize);
        canvas.addSubview(sizeStepper, UXGeom.make((i16)286, (i16)28, (i16)20, (i16)28));
        boldBox = new UXCheckbox();
        boldBox.setTitle((u8*)"Bold");
        boldBox.setChecked(fdesc.bold);
        boldBox.setAction(&self.onBold);
        canvas.addSubview(boldBox, UXGeom.make((i16)238, (i16)74, (i16)120, (i16)20));
        italicBox = new UXCheckbox();
        italicBox.setTitle((u8*)"Italic");
        italicBox.setChecked(fdesc.italic);
        italicBox.setAction(&self.onItalic);
        canvas.addSubview(italicBox, UXGeom.make((i16)238, (i16)100, (i16)120, (i16)20));
        }
    // Mark a LOCAL rect of the board, not the whole board.  setNeedsDisplayInRect takes absolute
    // coordinates (what the tree accumulates), so add our origin; the board is the size of the
    // window, and marking all of it for a changed size read-out is what made one click repaint
    // 167kpx.  See setNeedsDisplayInRect: "redraw only part of me".
    void dirty(i16 x, i16 y, i16 w, i16 h)
        {
        UXRect a = self.absoluteFrame();
        self.setNeedsDisplayInRect(UXGeom.make((i16)(a.x + x), (i16)(a.y + y), w, h));
        }
    // What a change actually touches, and no more.  The description line and the preview always
    // restate the whole descriptor, so any edit dirties those two; the size read-out beside the
    // stepper only ever changes when the SIZE does — marking it for a family click repainted the top
    // of the window for nothing.
    void redrawDesc(void)
        {
        self.dirty((i16)238, (i16)126, (i16)230, (i16)26); // "Lora 18 Bold Italic"
        self.dirty((i16)18, (i16)200, (i16)446, (i16)102); // "Preview" label + the framed box
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    void redrawSize(void)
        {
        self.dirty((i16)238, (i16)26, (i16)230, (i16)28); // the size read-out only
        self.redrawDesc();
        }

    void selectFamily(i32 i)
        {
        i32 was = selFamily;
        selFamily = i;
        fdesc.family = self.familyAt(i);
        // the two that changed
        if (list != (KSFontListView*)0)
            {
            list.dirtyRow(was);
            list.dirtyRow(i);
            }
        self.redrawDesc();
        }
    void onSize(UXControl* c)
        {
        fdesc.size = (i16)sizeStepper.intValue();
        self.redrawSize();
        }
    void onBold(UXControl* c)
        {
        fdesc.bold = boldBox.isChecked();
        self.redrawDesc();
        }
    void onItalic(UXControl* c)
        {
        fdesc.italic = italicBox.isChecked();
        self.redrawDesc();
        }

    void frame(UXGraphics* g, UXRect r, i32 pen)
        {
        g.drawLine(r.x, r.y, (i16)(r.x + r.w), r.y, pen);
        g.drawLine(r.x, (i16)(r.y + r.h), (i16)(r.x + r.w), (i16)(r.y + r.h), pen);
        g.drawLine(r.x, r.y, r.x, (i16)(r.y + r.h), pen);
        g.drawLine((i16)(r.x + r.w), r.y, (i16)(r.x + r.w), (i16)(r.y + r.h), pen);
        }
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)8); // grey backdrop
        g.drawText((u8*)"Family", (i16)18, (i16)12, (i32)1, (i32)0);
        g.drawText((u8*)"Size", (i16)238, (i16)12, (i32)1, (i32)0);
        g.drawText(UXStr.fromInt((i32)fdesc.size), (i16)314, (i16)34, (i32)1, (i32)0); // live size read-out beside the stepper
        g.drawText(fdesc.description(), (i16)238, (i16)134, (i32)1, (i32)0);           // "Lora 18 Bold Italic"
        // the preview: the chosen family, size and bold/italic actually rendered (drawTextFont selects the
        // face — a real font on Win32/Cocoa, the matching vst_font face on GEM, with synthesised bold/italic).
        g.drawText((u8*)"Preview", (i16)18, (i16)202, (i32)1, (i32)0);
        UXRect pv = UXGeom.make((i16)18, (i16)218, (i16)444, (i16)82);
        g.fillRect(pv, (i32)0);
        self.frame(g, pv, (i32)1);
        g.drawTextFont((u8*)"The quick brown fox", (i16)26, (i16)226, (i32)1, fdesc.family, (i32)fdesc.size, fdesc.bold, fdesc.italic);
        }
    }

    // The table's data (a tiny file listing).  Static strings: valueForCell hands the pointer straight
    // to the cell, uncopied.
    u8* ksName[KS_ROWS];
u8* ksSize[KS_ROWS];
u8* ksKind[KS_ROWS];

// ---- the text board: UXTextLayout with a face on it --------------------------------------------
// The line breaker measures the font it will be drawn in (driver.textWidth), so the wrap is the real
// one and not an estimate — which is only visible if you can RESIZE it: the paragraph re-flows as the
// window changes, and the size stepper re-flows it again at a different measure.
#define KT_MARGIN 16
#define KT_TOP 52 // below the size row

u8 ksTextLine[512]; // one line copied out for drawing (a line is a range, not a string)

class KSTextBoard : UXView
    {
    UXAttributedString* rich;
    UXStepper* sizeStepper;
    UXPopUpButton* alignPop;
    UXLabel* tally;
    i32 size;
    void init(void)
        {
        super.init();
        // Styled ranges over one string: the wrap measures each in its own font (bold IS wider), and
        // each run draws in its own font — so what is measured and what is drawn are the same thing.
        rich = UXAttributedString.make((u8*)"The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.\nA second paragraph follows an explicit newline, and wraps on its own.");
        rich.setBold(true, (i32)4, (i32)5);     // "quick"
        rich.setItalic(true, (i32)10, (i32)5);  // "brown"
        rich.setColor((i32)2, (i32)16, (i32)3); // "fox" in red
        rich.setSize((i16)22, (i32)44, (i32)4); // "Pack" larger
        sizeStepper = (UXStepper*)0;
        alignPop = (UXPopUpButton*)0;
        tally = (UXLabel*)0;
        size = (i32)16;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }

    void setup(UXView* canvas)
        {
        sizeStepper = new UXStepper();
        sizeStepper.setRange((i32)8, (i32)40);
        sizeStepper.setValue(size);
        sizeStepper.setAction(&self.onSize);
        canvas.addSubview(sizeStepper, UXGeom.make((i16)86, (i16)14, (i16)20, (i16)28));
        alignPop = new UXPopUpButton();
        alignPop.addItem((u8*)"Left", (i32)UX_ALIGN_LEFT);
        alignPop.addItem((u8*)"Centred", (i32)UX_ALIGN_CENTER);
        alignPop.addItem((u8*)"Right", (i32)UX_ALIGN_RIGHT);
        alignPop.addItem((u8*)"Justified", (i32)UX_ALIGN_JUSTIFY);
        alignPop.setAction(&self.onSize); // any change re-flows the same way
        canvas.addSubview(alignPop, UXGeom.make((i16)120, (i16)14, (i16)110, (i16)24));
        tally = new UXLabel();
        tally.setText((u8*)"");
        canvas.addSubview(tally, UXGeom.make((i16)244, (i16)20, (i16)220, (i16)16));
        }
    void onSize(UXControl* c)
        {
        size = sizeStepper.intValue();
        self.setNeedsDisplay(); // the whole board: every line re-flows
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    // A run is a (start,length) range into the paragraph — copy it out to hand to drawTextFont.
    u8* runText(i32 start, i32 len)
        {
        u8* para = rich.stringValue();
        if (len > (i32)511)
            {
            len = (i32)511;
            }
        for (i32 k = (i32)0; k < len; k = k + (i32)1)
            {
            ksTextLine[k] = para[start + k];
            }
        ksTextLine[len] = (u8)0;
        return (u8*)&ksTextLine[(i32)0];
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)8);
        g.drawText((u8*)"Size", (i16)18, (i16)20, (i32)1, (i32)0);
        i16 measure = (i16)((i32)b.w - (i32)KT_MARGIN * (i32)2);
        i32 align = alignPop != (UXPopUpButton*)0 ? alignPop.selectedTag() : (i32)UX_ALIGN_LEFT;
        Array<UXRange>* lines = UXTextLayout.wrapAttr(rich, measure, size);
        u8* para = rich.stringValue();
        i16 lh = (i16)(size + (i32)10); // room for a run set larger than the base size
        i16 y = (i16)KT_TOP;
        for (u16 i = (u16)0; i < lines.count(); i = i + (u16)1)
            {
            // clip to the window
            if ((i32)y + (i32)lh > (i32)b.h)
                {
                break;
                }
            UXRange* ln = (UXRange* ?)lines.get(i);
            bool isLast = UXTextLayout.isParagraphEnd(para, lines, i);
            Array<UXTextRun>* runs = UXTextLayout.layoutLineAttr(rich, ln, measure, size, align, isLast);
            for (u16 r = (u16)0; r < runs.count(); r = r + (u16)1)
                {
                UXTextRun* run = (UXTextRun* ?)runs.get(r);
                UXCharAttr* a = run.attr;
                i32 rs = a != (UXCharAttr*)0 && a.size > (i16)0 ? (i32)a.size : size;
                i32 pen = a != (UXCharAttr*)0 ? a.pen : (i32)1;
                bool bo = a != (UXCharAttr*)0 ? a.bold : false;
                bool it = a != (UXCharAttr*)0 ? a.italic : false;
                g.drawTextFont(self.runText(run.loc, run.len),
                               (i16)((i32)KT_MARGIN + run.x), y, pen, (u8*)"", rs, bo, it);
                }
            y = (i16)((i32)y + (i32)lh);
            }
        // The right margin, so a too-long line would be obvious rather than merely off.
        g.drawLine((i16)((i32)b.w - (i16)KT_MARGIN), (i16)KT_TOP, (i16)((i32)b.w - (i16)KT_MARGIN), (i16)((i32)b.h - (i32)8), (i32)9);
        if (tally != (UXLabel*)0)
            {
            u8* t = UXStr.append(UXStr.fromInt((i32)lines.count()), (u8*)" lines at ");
            t = UXStr.append(t, UXStr.fromInt((i32)measure));
            tally.setText(UXStr.append(t, (u8*)"px — resize me"));
            }
        }
    }

// ---- the rules board: UXPredicate with a face on it --------------------------------------------
// The rule engine (UXPredicate) is a model — comparisons, CONTAINS/BEGINSWITH/ENDSWITH/MATCHES,
// AND/OR/NOT, nesting.  This is the view over it: rule rows that build a predicate TREE, evaluated
// live against the same eight records the main window tables.  Every edit rebuilds the tree from
// scratch and re-filters; there is no incremental state to get out of step.
#define KR_MAXROWS 4 // rows the board can hold (all built up front, surplus ones hidden)
#define KR_ROWY 44   // first row's y; rows are KR_ROWH apart
#define KR_ROWH 30
#define KR_ALL 0  // "Match All"  -> AND
#define KR_ANY 1  // "Match Any"  -> OR
#define KR_NONE 2 // "Match None" -> NOT(OR(...))

    // One record the engine can read.  valueForKey IS the whole contract — the engine never learns
    // what a "file" is, and this class never learns what a predicate is.
    class KSRecord : Object<UXEvaluable>
    {
    u8* vName;
    u8* vSize;
    u8* vKind;
    void init(void)
        {
        vName = (u8*)"";
        vSize = (u8*)"";
        vKind = (u8*)"";
        }
    u8* valueForKey(u8* k)
        {
        if (UXPredicate.streq(k, (u8*)"name"))
            {
            return vName;
            }
        if (UXPredicate.streq(k, (u8*)"size"))
            {
            return vSize;
            }
        if (UXPredicate.streq(k, (u8*)"kind"))
            {
            return vKind;
            }
        return (u8*)"";
        }
    }

    // Board state as globals, like the font chooser's family cache: one Rules window at a time, and it
    // keeps the per-row widget arrays out of the class (a class field array is not needed for a singleton).
    // The dataset lives in an Array, NOT a bare `KSRecord* ksRecs[KS_ROWS]`: a global array of object
    // refs does not own what it holds, so the records — which nothing else retains — would die as soon
    // as the loop that built them moved on, and evaluating a rule would then read freed memory.  The
    // widget arrays below are safe because the view tree owns those objects; this one had no owner.
    Array<KSRecord>* ksRecs; // the dataset the rules run over (8 KSRecords)
i32 ksMatch[KS_ROWS];        // matching record indices — the first ksMatchN are live
i32 ksMatchN;
UXPopUpButton* ksrKey[KR_MAXROWS];
UXPopUpButton* ksrOp[KR_MAXROWS];
UXTextField* ksrVal[KR_MAXROWS];
UXButton* ksrDel[KR_MAXROWS];

// ---- the vector board: a thick bezier with caps, a coloured outline and a radial fill ----------
// This is the drawing subsystem on show: curves stored in UXShapePath, flattened adaptively, stroked
// by UXPainter into convex polygons, and handed to the one fillPolygon seam.  Nothing here is
// per-backend — GEM, Win32 and AppKit run this same code and get the same pixels, which is the whole
// argument for stroking neutrally rather than reaching for VDI/GDI/Cocoa stroke calls that disagree.
class KSVectorBoard : UXView
    {
    UXShapePath* curve;        // the 16px stroked bezier, round cap one end, arrowhead the other
    Array<UXShapePath>* thins; // the same curve at 1..5px — what most beziers actually are
    UXShapePath* blob;         // a closed curved shape, radially filled
    UXGradient* grad;
    i32 width;     // stroke width, driven by the stepper
    i32 bands;     // radial bands, driven by the popup
    bool showHull; // draw the control polygon, so the curve can be read against it

    void init(void)
        {
        super.init();
        curve = (UXShapePath*)0;
        blob = (UXShapePath*)0;
        grad = (UXGradient*)0;
        thins = (Array*)0;
        width = (i32)16;
        bands = (i32)24;
        showHull = false;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }

    void build(void)
        {
        // A 32-point path: seven cubics end to end, which is what "a bezier with 32 points" means in
        // practice — one continuous curve made of segments sharing anchors.
        curve = new UXShapePath();
        curve.moveTo((i16)40, (i16)150);
        curve.curveTo((i16)70, (i16)60, (i16)110, (i16)60, (i16)140, (i16)150);
        curve.curveTo((i16)170, (i16)240, (i16)210, (i16)240, (i16)240, (i16)150);
        curve.curveTo((i16)270, (i16)60, (i16)310, (i16)60, (i16)340, (i16)150);
        curve.setStartCap((i32)UXCAP_ROUND);
        curve.setEndCap((i32)UXCAP_ARROW);

        // A CIRCLE, as four cubics with the classic k = 0.5523 control offset (k*r = 17 at r = 30).
        // It was two cubics making a lozenge, which is a fine test of curve joining and a poor test
        // of curve QUALITY: a lozenge has flattish sides, so it looked faceted whatever the
        // flattener did, and there was no way to tell the demo's shape from the toolkit's error.
        // A circle has a right answer you can see.
        blob = new UXShapePath();
        blob.moveTo((i16)120, (i16)232);
        blob.curveTo((i16)137, (i16)232, (i16)150, (i16)245, (i16)150, (i16)262);
        blob.curveTo((i16)150, (i16)279, (i16)137, (i16)292, (i16)120, (i16)292);
        blob.curveTo((i16)103, (i16)292, (i16)90, (i16)279, (i16)90, (i16)262);
        blob.curveTo((i16)90, (i16)245, (i16)103, (i16)232, (i16)120, (i16)232);
        blob.close();

        // THIN strokes, 1 to 5 pixels — the widths most curves are actually drawn at, and the ones
        // most likely to break: at 1px the half-width is half a pixel, so the two edges of a quad can
        // round to the same coordinate, and the join disc is skipped entirely (there is no room for
        // one), leaving consecutive quads to meet edge to edge on a curve.
        thins = new Array();
        for (i32 k = (i32)0; k < (i32)5; k = k + (i32)1)
            {
            i32 x = (i32)16 + k * (i32)76;
            UXShapePath* t = new UXShapePath();
            t.moveTo((i16)x, (i16)340);
            t.curveTo((i16)(x + (i32)14), (i16)306, (i16)(x + (i32)48), (i16)306,
                      (i16)(x + (i32)62), (i16)340);
            thins.add(t);
            }

        grad = new UXGradient();
        grad.addStop((i32)0, UXColor.rgb((i32)255, (i32)240, (i32)120)); // centre
        grad.addStop((i32)140, UXColor.rgb((i32)240, (i32)120, (i32)40));
        grad.addStop((i32)255, UXColor.rgb((i32)120, (i32)30, (i32)90)); // edge
        }

    void setWidth(i32 w)
        {
        width = w < (i32)1 ? (i32)1 : (w > (i32)40 ? (i32)40 : w);
        self.setNeedsDisplay();
        }
    void setBands(i32 b)
        {
        bands = b;
        self.setNeedsDisplay();
        }
    void setHull(bool on)
        {
        showHull = on;
        self.setNeedsDisplay();
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRect(b, (i32)0);
        if (curve == (UXShapePath*)0)
            {
            self.build();
            }

        // The stroke, twice: a fatter pass underneath in a dark pen is the OUTLINE, the real width
        // on top in the fill colour.  Two strokes rather than an outline primitive, because that is
        // all an outlined stroke is and it needs nothing from any backend.
        UXPainter.strokeOutlined(g, curve, (i16)width, UXPainter.rgb((i32)80, (i32)170, (i32)255),
                                 (i32)1, (i16)3);

        // The radial fill, with a stroked outline of its own.
        UXPainter.fillShapeRadial(g, blob, grad, bands);
        UXPainter.strokePath(g, blob, (i16)3, (i32)1);

        // The flattening, ON TOP of the stroke: a dot at every point the curve was reduced to.  It
        // was drawn UNDER the stroke, where the stroke covered it completely and the checkbox looked
        // like it did nothing at all.  Dots rather than lines, because the polyline follows the
        // centre of an opaque stroke and a line along it is invisible either way.
        if (showHull)
            {
            UXShapePath* f = curve.flattened();
            for (i32 i = (i32)0; i < f.elementCount(); i = i + (i32)1)
                {
                UXPathElement* e = f.elemAt(i);
                if (e.type == (i32)UXPE_CLOSE)
                    {
                    continue;
                    }
                g.fillRect(UXGeom.make((i16)((i32)e.x - (i32)1), (i16)((i32)e.y - (i32)1),
                                       (i16)3, (i16)3),
                           (i32)2);
                }
            }

        // 1..5px, left to right.  A thin curve is the common case and the awkward one.
        for (i32 k = (i32)0; k < (i32)5; k = k + (i32)1)
            {
            UXShapePath* t = (UXShapePath* ?)thins.get((u16)k);
            UXPainter.strokePath(g, t, (i16)(k + (i32)1), (i32)1);
            }
        g.drawText((u8*)"1px", (i16)30, (i16)356, (i32)1, (i32)0);
        g.drawText((u8*)"2px", (i16)106, (i16)356, (i32)1, (i32)0);
        g.drawText((u8*)"3px", (i16)182, (i16)356, (i32)1, (i32)0);
        g.drawText((u8*)"4px", (i16)258, (i16)356, (i32)1, (i32)0);
        g.drawText((u8*)"5px", (i16)334, (i16)356, (i32)1, (i32)0);

        g.drawText((u8*)"16px bezier, round cap -> arrowhead", (i16)16, (i16)18, (i32)1, (i32)0);
        g.drawText((u8*)"closed curve,", (i16)170, (i16)252, (i32)1, (i32)0);
        g.drawText((u8*)"centre-to-edge fill,", (i16)170, (i16)268, (i32)1, (i32)0);
        g.drawText((u8*)"stroked outline", (i16)170, (i16)284, (i32)1, (i32)0);
        }
    }

    class KSRulesBoard : UXView<UXTableDataSource>
    {
    UXPopUpButton* modePop; // All / Any / None
    UXTableView* result;    // the rows that match
    UXLabel* tally;         // "N of 8 rows match"
    UXButton* addBtn;
    i32 nRows; // rule rows currently in use (the rest are hidden)

    void init(void)
        {
        super.init();
        modePop = (UXPopUpButton*)0;
        result = (UXTableView*)0;
        tally = (UXLabel*)0;
        addBtn = (UXButton*)0;
        nRows = (i32)2;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }

    // ---- the dataset ---------------------------------------------------------
    // Wrap the table's columns as records once; the rules re-run over these, not over the strings.
    void loadRecords(void)
        {
        // built once; reopening reuses them
        if (ksRecs != (Array*)0)
            {
            return;
            }
        ksRecs = new Array();
        for (i32 i = (i32)0; i < (i32)KS_ROWS; i = i + (i32)1)
            {
            KSRecord* r = new KSRecord();
            r.vName = ksName[i];
            r.vSize = ksSize[i];
            r.vKind = ksKind[i];
            ksRecs.add(r);
            }
        }
    KSRecord* recordAt(i32 i)
        { return (KSRecord* ?)ksRecs.get((u16)i);
        }

    // ---- building the predicate ----------------------------------------------
    // A row with an empty value is INACTIVE — half-typed rules must not make the table jump about.
    // With no active row there is nothing to filter on, so everything matches (a bare OR of nothing
    // would say the opposite, which is why this is not left to the compound's own empty case).
    UXPredicate* buildPredicate(void)
        {
        i32 mode = modePop != (UXPopUpButton*)0 ? modePop.selectedTag() : (i32)KR_ALL;
        UXPredicate* inner = UXPredicate.compound(mode == (i32)KR_ALL ? (i32)UXP_AND : (i32)UXP_OR);
        i32 active = (i32)0;
        for (i32 i = (i32)0; i < nRows; i = i + (i32)1)
            {
            u8* v = ksrVal[i].text();
            if (v == (u8*)0 || v[(i32)0] == (u8)0)
                {
                continue;
                }
            inner.addSub(UXPredicate.comparison(self.keyOf(i), ksrOp[i].selectedTag(), v));
            active = active + (i32)1;
            }
        // no rules -> no filtering
        if (active == (i32)0)
            {
            return (UXPredicate*)0;
            }
        if (mode == (i32)KR_NONE)
            {
            return UXPredicate.not(inner);
            }
        return inner;
        }
    // The key path a row selects.  The popup shows "Name"; the engine wants "name".
    u8* keyOf(i32 i)
        {
        i32 t = ksrKey[i].selectedTag();
        if (t == (i32)1)
            {
            return (u8*)"size";
            }
        if (t == (i32)2)
            {
            return (u8*)"kind";
            }
        return (u8*)"name";
        }

    // Re-run the rules over every record and republish the result.  Cheap enough (8 records) that
    // it can happen on every keystroke, which is what makes the board feel live.
    void applyRules(void)
        {
        UXPredicate* p = self.buildPredicate();
        ksMatchN = (i32)0;
        for (i32 i = (i32)0; i < (i32)KS_ROWS; i = i + (i32)1)
            {
            if (p == (UXPredicate*)0 || p.evaluate(self.recordAt(i)))
                {
                ksMatch[ksMatchN] = i;
                ksMatchN = ksMatchN + (i32)1;
                }
            }
        if (result != (UXTableView*)0)
            {
            result.reloadData();
            result.setNeedsDisplay();
            }
        if (tally != (UXLabel*)0)
            {
            u8* s = UXStr.append(UXStr.fromInt(ksMatchN), (u8*)" of 8 rows match");
            tally.setText(p == (UXPredicate*)0 ? UXStr.append(s, (u8*)"  (no rules yet)") : s);
            }
        // NOT the whole board: the table and the tally label each damage themselves, and the rest of
        // what this view draws (the "Match"/"of the following rules:" text, the divider) never changes.
        // Marking the board marked the window — 208kpx for a filter that moved a few table rows.
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }

    // ---- table datasource: the matching records ------------------------------
    i32 numberOfRows(UXTableView* t)
        {
        return ksMatchN;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (row < (i32)0 || row >= ksMatchN)
            {
            return (u8*)"";
            }
        i32 r = ksMatch[row];
        if (col == (i32)0)
            {
            return ksName[r];
            }
        if (col == (i32)1)
            {
            return ksSize[r];
            }
        return ksKind[r];
        }

    // ---- actions -------------------------------------------------------------
    // live, per keystroke
    void onEdit(UXTextField* f)
        {
        self.applyRules();
        }
    // a popup changed
    void onPick(UXControl* c)
        {
        self.applyRules();
        }
    // and the explicit button
    void onApply(UXControl* c)
        {
        self.applyRules();
        }
    void onAdd(UXControl* c)
        {
        if (nRows >= (i32)KR_MAXROWS)
            {
            return;
            }
        ksrVal[nRows].setText((u8*)"");
        nRows = nRows + (i32)1;
        self.syncRowVisibility();
        self.applyRules();
        }
    // Deleting row i shifts the rows below it up, so the live rows stay a contiguous block and no
    // widget has to move.  One bound method per row: the action carries the control, not an index.
    void onDel0(UXControl* c)
        {
        self.removeRow((i32)0);
        }
    void onDel1(UXControl* c)
        {
        self.removeRow((i32)1);
        }
    void onDel2(UXControl* c)
        {
        self.removeRow((i32)2);
        }
    void onDel3(UXControl* c)
        {
        self.removeRow((i32)3);
        }
    void removeRow(i32 i)
        {
        // always keep one row
        if (i < (i32)0 || i >= nRows || nRows <= (i32)1)
            {
            return;
            }
        for (i32 j = i; j < nRows - (i32)1; j = j + (i32)1)
            {
            ksrKey[j].selectItem(ksrKey[j + (i32)1].selectedIndex());
            ksrOp[j].selectItem(ksrOp[j + (i32)1].selectedIndex());
            ksrVal[j].setText(ksrVal[j + (i32)1].text());
            }
        nRows = nRows - (i32)1;
        ksrVal[nRows].setText((u8*)"");
        self.syncRowVisibility();
        self.applyRules();
        }
    // Surplus rows stay built but hidden — the tree is finalised once, so rows are revealed, not created.
    void syncRowVisibility(void)
        {
        for (i32 i = (i32)0; i < (i32)KR_MAXROWS; i = i + (i32)1)
            {
            bool on = i < nRows;
            ksrKey[i].setHidden(!on);
            ksrOp[i].setHidden(!on);
            ksrVal[i].setHidden(!on);
            ksrDel[i].setHidden(!on);
            }
        if (addBtn != (UXButton*)0)
            {
            addBtn.setEnabled(nRows < (i32)KR_MAXROWS);
            }
        }

    // ---- construction --------------------------------------------------------
    void addRuleRow(UXView* canvas, i32 i)
        {
        i16 y = (i16)((i32)KR_ROWY + i * (i32)KR_ROWH);
        UXPopUpButton* k = new UXPopUpButton();
        k.addItem((u8*)"Name", (i32)0);
        k.addItem((u8*)"Size", (i32)1);
        k.addItem((u8*)"Kind", (i32)2);
        k.setAction(&self.onPick);
        canvas.addSubview(k, UXGeom.make((i16)18, y, (i16)92, (i16)24));
        ksrKey[i] = k;
        // The operator list IS the engine's op set — the tags are the UXP_* codes, handed straight
        // to UXPredicate.comparison, so adding an operator here needs no translation table.
        UXPopUpButton* o = new UXPopUpButton();
        o.addItem((u8*)"contains", (i32)UXP_CONTAINS);
        o.addItem((u8*)"begins with", (i32)UXP_BEGINSWITH);
        o.addItem((u8*)"ends with", (i32)UXP_ENDSWITH);
        o.addItem((u8*)"is", (i32)UXP_EQ);
        o.addItem((u8*)"is not", (i32)UXP_NE);
        o.addItem((u8*)"matches", (i32)UXP_MATCHES);
        o.addItem((u8*)"greater than", (i32)UXP_GT);
        o.addItem((u8*)"less than", (i32)UXP_LT);
        o.setAction(&self.onPick);
        canvas.addSubview(o, UXGeom.make((i16)116, y, (i16)124, (i16)24));
        ksrOp[i] = o;
        UXTextField* v = new UXTextField();
        v.setPlaceholder((u8*)"value…");
        v.setOnChange(&self.onEdit);
        canvas.addSubview(v, UXGeom.make((i16)246, (i16)(y + (i16)1), (i16)168, (i16)22));
        ksrVal[i] = v;
        UXButton* d = new UXButton();
        d.setTitle((u8*)"-");
        if (i == (i32)0)
            {
            d.setAction(&self.onDel0);
            }
        else if (i == (i32)1)
            {
            d.setAction(&self.onDel1);
            }
        else if (i == (i32)2)
            {
            d.setAction(&self.onDel2);
            }
        else
            {
            d.setAction(&self.onDel3);
            }
        canvas.addSubview(d, UXGeom.make((i16)422, y, (i16)28, (i16)24));
        ksrDel[i] = d;
        }

    void setup(UXView* canvas)
        {
        self.loadRecords();
        modePop = new UXPopUpButton();
        modePop.addItem((u8*)"All", (i32)KR_ALL);
        modePop.addItem((u8*)"Any", (i32)KR_ANY);
        modePop.addItem((u8*)"None", (i32)KR_NONE);
        modePop.setAction(&self.onPick);
        canvas.addSubview(modePop, UXGeom.make((i16)70, (i16)8, (i16)76, (i16)24));
        for (i32 i = (i32)0; i < (i32)KR_MAXROWS; i = i + (i32)1)
            {
            self.addRuleRow(canvas, i);
            }
        addBtn = new UXButton();
        addBtn.setTitle((u8*)"+ Add rule");
        addBtn.setAction(&self.onAdd);
        canvas.addSubview(addBtn, UXGeom.make((i16)18, (i16)((i32)KR_ROWY + (i32)KR_MAXROWS * (i32)KR_ROWH), (i16)92, (i16)24));
        result = new UXTableView();
        canvas.addSubview(result, UXGeom.make((i16)18, (i16)210, (i16)450, (i16)176));
        result.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        result.setRowHeight((i16)22);
        result.addColumn((u8*)"Name", (i16)210);
        result.addColumn((u8*)"Size", (i16)80);
        result.addColumn((u8*)"Kind", (i16)150);
        result.setDataSource(self);
        tally = new UXLabel();
        tally.setText((u8*)"8 of 8 rows match");
        canvas.addSubview(tally, UXGeom.make((i16)18, (i16)394, (i16)240, (i16)16));
        tally.setAutoresizeMask((i32)UX_ANCHOR_BOTTOM);
        // A seeded rule, so the window opens showing the engine doing something rather than a blank form.
        ksrKey[(i32)0].selectByTag((i32)2);
        ksrOp[(i32)0].selectByTag((i32)UXP_EQ);
        ksrVal[(i32)0].setText((u8*)"Source");
        ksrKey[(i32)1].selectByTag((i32)0);
        ksrOp[(i32)1].selectByTag((i32)UXP_CONTAINS);
        self.syncRowVisibility();
        self.applyRules();
        }

    void drawRect(UXGraphics* g, UXRect dirty)
        {
        UXRect b = self.bounds();
        g.fillRect(UXGeom.make((i16)0, (i16)0, b.w, b.h), (i32)8); // grey backdrop
        g.drawText((u8*)"Match", (i16)18, (i16)14, (i32)1, (i32)0);
        g.drawText((u8*)"of the following rules:", (i16)154, (i16)14, (i32)1, (i32)0);
        g.drawLine((i16)18, (i16)200, (i16)(b.w - (i16)18), (i16)200, (i32)1); // rule/result divider
        g.drawText((u8*)"Matching rows", (i16)18, (i16)188, (i32)1, (i32)0);
        }
    }

    class KitchenSink : Object<UXApplicationDelegate, UXTableDataSource, UXTableDelegate>
    {
    UXApplication* app;
    UXWindow* win;
    UXTextField* field;
    UXTextField* secret; // a masked password field (AppKit/Win32; GEM shows plain text)
    UXCheckbox* subscribe;
    UXRadioGroup* via;
    UXLabel* status;
    UXWindow* treeWin; // a second window: a file tree in a native outline
    UXOutlineView* tree;
    KSTree* fileTree;
    UXWindow* scrollWin; // a scroll-view window (native scroller over a tall list)
    UXWindow* splitWin;  // a split-view window (two resizable panes + a divider)
    UXWindow* widgetWin; // a widgets window: slider/progress/stepper/popup/segmented/toolbar
    UXWindow* dragWin;   // an in-app drag-and-drop board
    UXWindow* colourWin; // the toolkit colour-picker window (GEM)
    KSColourBoard* colourBoard;
    UXColor* pickedColor; // the last-chosen colour (seeds the picker; reported on Select)
    UXWindow* rulesWin;   // the rule editor over UXPredicate (live filtering)
    KSRulesBoard* rulesBoard;
    UXWindow* vectorWin;
    UXStepper* vecWidth;
    UXStepper* vecBands;
    UXCheckbox* vecHull;
    KSVectorBoard* vectorBoard;
    UXWindow* textWin; // the wrapped-paragraph window over UXTextLayout
    KSTextBoard* textBoard;
    UXWindow* recWin; // capture / replay of the event stream
    UXEventRecorder* recorder;
    UXTableView* recTable; // something with SELECTION and SCROLLING to record against
    UXCheckbox* recCheck;
    UXTextField* recField;
    UXLabel* recStatus;
    UXWindow* fontWin; // the toolkit font-chooser window (GEM/Win32)
    KSFontBoard* fontBoard;
    UXFont* pickedFont; // the last-chosen font (seeds the chooser; reported on Select)
    UXSlider* slider;   // drives the progress bar
    UXProgressBar* progBar;
    UXProgress* prog;
    UXStepper* stepper;
    UXLabel* stepVal; // live read-out beside the stepper

    // ---- table datasource / delegate -----------------------------------------
    // MORE ROWS THAN FIT, deliberately: this is the window that demonstrates recording a scroll, and
    // with exactly a viewport's worth of rows there was nothing to scroll — the demo showed selection
    // and typing but never the thing it was built for.  The eight names repeat.
    i32 numberOfRows(UXTableView* t)
        {
        return (i32)KS_ROWS * (i32)5;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        if (row < (i32)0 || row >= (i32)KS_ROWS * (i32)5)
            {
            return (u8*)"";
            }
        i32 r = row % (i32)KS_ROWS;
        if (col == (i32)0)
            {
            return ksName[r];
            }
        if (col == (i32)1)
            {
            return ksSize[r];
            }
        return ksKind[r];
        }
    void tableSelectionDidChange(UXTableView* t, i32 row)
        {
        i32 n = t.selectedCount();
        if (n == (i32)0)
            {
            self.say((u8*)"(nothing selected)");
            }
        else if (n == (i32)1)
            {
            self.say(ksName[row]);
            }
        else
            {
            self.say(UXStr.append(UXStr.fromInt(n), (u8*)" rows selected"));
            }
        }

    void say(u8* s)
        {
        if (status != (UXLabel*)0)
            {
            status.setText(s);
            }
        }

    // ---- actions -------------------------------------------------------------
    void popAlert(void)
        {
        UXAlert* a = new UXAlert();
        a.icon = (i32)1;
        a.addLine((u8*)"UXKit Kitchen Sink");
        a.addLine((u8*)"One neutral toolkit, three native backends.");
        a.addButton((u8*)"Nice");
        a.addButton((u8*)"Meh");
        Stdio.printf("alert -> %d\n", a.runModal());
        }
    void onAlert(UXControl* c)
        {
        self.popAlert();
        }
    void onClear(UXControl* c)
        {
        field.setText((u8*)"");
        self.say((u8*)"field cleared");
        }
    // Live edit notification: every keystroke in the field echoes into the status line.
    void onType(UXTextField* f)
        {
        self.say(UXStr.append((u8*)"typing: ", f.text()));
        }
    void onQuit(UXControl* c)
        {
        app.stop();
        }
    void onSub(UXControl* c)
        {
        self.say(subscribe.isChecked() ? (u8*)"subscribed" : (u8*)"unsubscribed");
        }
    void onVia(UXControl* c)
        {
        self.say((u8*)"delivery method changed");
        }
    void onCorner(UXControl* c)
        {
        self.say((u8*)"corner button (stays anchored on resize)");
        }
    void onOpenFile(UXControl* c)
        {
        u8* p = UXOpenPanel.run((u8*)"Open", (u8*)"/");
        if (p != (u8*)0)
            {
            self.say(UXStr.append((u8*)"chose: ", p));
            }
        else
            {
            self.say((u8*)"open cancelled");
            }
        }

    void mAbout(UXMenuItem* s)
        {
        self.popAlert();
        }
    void mQuit(UXMenuItem* s)
        {
        app.stop();
        }
    void mClear(UXMenuItem* s)
        {
        field.setText((u8*)"");
        self.say((u8*)"field cleared (menu)");
        }

    // ---- widget-window actions -----------------------------------------------
    void onSlider(UXControl* c)
        {
        prog.setCompleted(slider.intValue());
        progBar.setNeedsDisplay();
        }
    void onStepper(UXControl* c)
        {
        stepVal.setText(UXStr.fromInt(stepper.intValue()));
        }
    void onPopup(UXControl* c)
        {
        self.say((u8*)"popup changed");
        }
    void onSeg(UXControl* c)
        {
        self.say((u8*)"segment changed");
        }
    void onTool(UXControl* c)
        {
        self.say((u8*)"toolbar item clicked");
        }

    // ---- the Windows menu: open a window the first time (or after it was closed), raise it otherwise --
    void mWinMain(UXMenuItem* s)
        {
        if (win == (UXWindow*)0 || !win.isOpen())
            {
            self.buildMain();
            }
        else
            {
            win.orderFront();
            }
        }
    void mWinFiles(UXMenuItem* s)
        {
        if (treeWin == (UXWindow*)0 || !treeWin.isOpen())
            {
            self.buildTree();
            }
        else
            {
            treeWin.orderFront();
            }
        }
    void mWinScroll(UXMenuItem* s)
        {
        if (scrollWin == (UXWindow*)0 || !scrollWin.isOpen())
            {
            self.buildScroll();
            }
        else
            {
            scrollWin.orderFront();
            }
        }
    void mWinSplit(UXMenuItem* s)
        {
        if (splitWin == (UXWindow*)0 || !splitWin.isOpen())
            {
            self.buildSplit();
            }
        else
            {
            splitWin.orderFront();
            }
        }
    void mWinWidgets(UXMenuItem* s)
        {
        if (widgetWin == (UXWindow*)0 || !widgetWin.isOpen())
            {
            self.buildWidgets();
            }
        else
            {
            widgetWin.orderFront();
            }
        }
    void mWinDrag(UXMenuItem* s)
        {
        if (dragWin == (UXWindow*)0 || !dragWin.isOpen())
            {
            self.buildDragDrop();
            }
        else
            {
            dragWin.orderFront();
            }
        }
    void mWinVector(UXMenuItem* s)
        {
        if (vectorWin == (UXWindow*)0 || !vectorWin.isOpen())
            {
            self.buildVector();
            }
        else
            {
            vectorWin.orderFront();
            }
        }
    void mWinRules(UXMenuItem* s)
        {
        if (rulesWin == (UXWindow*)0 || !rulesWin.isOpen())
            {
            self.buildRules();
            }
        else
            {
            rulesWin.orderFront();
            }
        }
    void mWinText(UXMenuItem* s)
        {
        if (textWin == (UXWindow*)0 || !textWin.isOpen())
            {
            self.buildText();
            }
        else
            {
            textWin.orderFront();
            }
        }
    void mWinRecord(UXMenuItem* s)
        {
        if (recWin == (UXWindow*)0 || !recWin.isOpen())
            {
            self.buildRecord();
            }
        else
            {
            recWin.orderFront();
            }
        }
    // Colours: present the OS colour picker directly where there is one (macOS NSColorPanel), else open
    // the toolkit wheel/sliders window (GEM).
    void mWinColour(UXMenuItem* s)
        {
        if (pickedColor == (UXColor*)0)
            {
            pickedColor = UXColor.rgb((i32)64, (i32)150, (i32)220);
            }
        if (gDriver.hasNativeColorPicker())
            {
            i32 r = pickedColor.r;
            i32 g = pickedColor.g;
            i32 b = pickedColor.b;
            if (gDriver.pickColor(pickedColor.r, pickedColor.g, pickedColor.b, &r, &g, &b) != (i32)0)
                {
                pickedColor = UXColor.rgb(r, g, b);
                self.reportColour();
                }
            return;
            }
        if (colourWin == (UXWindow*)0 || !colourWin.isOpen())
            {
            self.buildColour();
            }
        else
            {
            colourWin.orderFront();
            }
        }
    // Fonts: present the OS font panel directly where there is one (macOS NSFontPanel), else open the
    // toolkit family/size/style chooser window (GEM/Win32).
    void mWinFont(UXMenuItem* s)
        {
        if (pickedFont == (UXFont*)0)
            {
            pickedFont = UXFont.makeTraits((u8*)"System", (i16)18, false, false);
            }
        if (gDriver.hasNativeFontPicker())
            {
            u8 fam[128];
            i32 os = (i32)0;
            i32 ob = (i32)0;
            i32 oi = (i32)0;
            if (gDriver.pickFont(pickedFont.family, (i32)pickedFont.size, pickedFont.bold ? (i32)1 : (i32)0, pickedFont.italic ? (i32)1 : (i32)0,
                                 (u8*)&fam[0], (i32)128, &os, &ob, &oi) != (i32)0)
                {
                pickedFont = UXFont.makeTraits(UXStr.append((u8*)"", (u8*)&fam[0]), (i16)os, ob != (i32)0, oi != (i32)0);
                self.reportFont();
                }
            return;
            }
        if (fontWin == (UXWindow*)0 || !fontWin.isOpen())
            {
            self.buildFont();
            }
        else
            {
            fontWin.orderFront();
            }
        }

    // Built in pieces: one big applicationDidStart blows arm64's per-frame budget on all the
    // UXGeom.make struct temporaries, so each section is its own small function.
    void fillData(void)
        {
        ksName[0] = (u8*)"README.md";
        ksSize[0] = (u8*)"2 KB";
        ksKind[0] = (u8*)"Markdown";
        ksName[1] = (u8*)"main.xc";
        ksSize[1] = (u8*)"14 KB";
        ksKind[1] = (u8*)"Source";
        ksName[2] = (u8*)"UXWindow.xc";
        ksSize[2] = (u8*)"9 KB";
        ksKind[2] = (u8*)"Source";
        ksName[3] = (u8*)"logo.png";
        ksSize[3] = (u8*)"48 KB";
        ksKind[3] = (u8*)"Image";
        ksName[4] = (u8*)"notes.txt";
        ksSize[4] = (u8*)"1 KB";
        ksKind[4] = (u8*)"Text";
        ksName[5] = (u8*)"build.sh";
        ksSize[5] = (u8*)"512 B";
        ksKind[5] = (u8*)"Script";
        ksName[6] = (u8*)"data.json";
        ksSize[6] = (u8*)"22 KB";
        ksKind[6] = (u8*)"JSON";
        ksName[7] = (u8*)"Makefile";
        ksSize[7] = (u8*)"3 KB";
        ksKind[7] = (u8*)"Makefile";
        }

    void buildHeader(UXView* canvas)
        {
        UXLabel* title = new UXLabel();
        title.setText((u8*)"UXKit Kitchen Sink — one toolkit, three backends");
        canvas.addSubview(title, UXGeom.make((i16)16, (i16)14, (i16)430, (i16)16));
        title.setAutoresizeMask((i32)UX_FLEX_WIDTH);
        UXLabel* nameLbl = new UXLabel();
        nameLbl.setText((u8*)"Name:");
        canvas.addSubview(nameLbl, UXGeom.make((i16)16, (i16)44, (i16)46, (i16)18));
        field = new UXTextField();
        field.setPlaceholder((u8*)"type something…"); // grey prompt (AppKit/Win32; GEM starts empty)
        field.setOnChange(&self.onType);              // echo keystrokes into the status line
        canvas.addSubview(field, UXGeom.make((i16)64, (i16)42, (i16)220, (i16)22));
        UXLabel* pinLbl = new UXLabel();
        pinLbl.setText((u8*)"PIN:");
        canvas.addSubview(pinLbl, UXGeom.make((i16)292, (i16)44, (i16)32, (i16)18));
        secret = new UXTextField();
        secret.setSecure(true); // •••• on AppKit/Win32
        secret.setPlaceholder((u8*)"secret");
        canvas.addSubview(secret, UXGeom.make((i16)326, (i16)42, (i16)118, (i16)22));
        }

    void buildOptions(UXView* canvas)
        {
        subscribe = new UXCheckbox();
        subscribe.setTitle((u8*)"Subscribe to updates");
        subscribe.setAction(&self.onSub);
        canvas.addSubview(subscribe, UXGeom.make((i16)16, (i16)72, (i16)220, (i16)21)); // 21 tall = the check sprite
        via = new UXRadioGroup();
        UXRadioButton* sms = new UXRadioButton();
        sms.setTitle((u8*)"SMS");
        sms.setAction(&self.onVia);
        via.add(sms);
        canvas.addSubview(sms, UXGeom.make((i16)16, (i16)97, (i16)70, (i16)21));
        UXRadioButton* email = new UXRadioButton();
        email.setTitle((u8*)"Email");
        email.setAction(&self.onVia);
        via.add(email);
        canvas.addSubview(email, UXGeom.make((i16)100, (i16)97, (i16)90, (i16)21));
        via.select(sms);
        }

    void buildTable(UXView* canvas)
        {
        UXTableView* table = new UXTableView();
        canvas.addSubview(table, UXGeom.make((i16)16, (i16)124, (i16)428, (i16)150));
        table.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        table.setAllowsMultipleSelection(true);
        table.setRowHeight((i16)22);
        table.addColumn((u8*)"Name", (i16)200);
        table.addColumn((u8*)"Size", (i16)70);
        table.addColumn((u8*)"Kind", (i16)140);
        table.setDataSource(self);
        table.setDelegate(self);
        table.reloadData();
        }

    void buildButton(UXView* canvas, u8* t, callback act void(UXControl* sender), i32 x, i32 mask)
        {
        UXButton* b = new UXButton();
        b.setTitle(t);
        b.setAction(act);
        canvas.addSubview(b, UXGeom.make((i16)x, (i16)286, (i16)90, (i16)28));
        b.setAutoresizeMask(mask);
        }

    void buildButtons(UXView* canvas)
        {
        self.buildButton(canvas, (u8*)"Alert", &self.onAlert, (i32)16, (i32)UX_ANCHOR_BOTTOM);
        self.buildButton(canvas, (u8*)"Clear", &self.onClear, (i32)114, (i32)UX_ANCHOR_BOTTOM);
        self.buildButton(canvas, (u8*)"Quit", &self.onQuit, (i32)212, (i32)UX_ANCHOR_BOTTOM);
        self.buildButton(canvas, (u8*)"Open File", &self.onOpenFile, (i32)310, (i32)UX_ANCHOR_BOTTOM);
        UXButton* corner = new UXButton();
        corner.setTitle((u8*)"Corner");
        corner.setAction(&self.onCorner);
        canvas.addSubview(corner, UXGeom.make((i16)354, (i16)376, (i16)90, (i16)28));
        corner.setAutoresizeMask((i32)UX_ANCHOR_RIGHT | (i32)UX_ANCHOR_BOTTOM);
        status = new UXLabel();
        status.setText((u8*)"resize me, click a row, type in the field, use the menu");
        canvas.addSubview(status, UXGeom.make((i16)16, (i16)392, (i16)430, (i16)16));
        status.setAutoresizeMask((i32)UX_ANCHOR_BOTTOM | (i32)UX_FLEX_WIDTH);
        }

    // A second window: a file tree, shown as a native outline (NSOutlineView / SysTreeView32 /
    // the GEM box path) from ONE item-based datasource.
    void buildTree(void)
        {
        fileTree = new KSTree();
        fileTree.root = ksNode((u8*)"/");
        KSNode* docs = ksNode((u8*)"Documents");
        docs.kids.add(ksNode((u8*)"report.txt"));
        docs.kids.add(ksNode((u8*)"notes.txt"));
        KSNode* src = ksNode((u8*)"src");
        src.kids.add(ksNode((u8*)"main.xc"));
        src.kids.add(ksNode((u8*)"UXWindow.xc"));
        docs.kids.add(src);
        KSNode* pics = ksNode((u8*)"Pictures");
        pics.kids.add(ksNode((u8*)"cat.png"));
        pics.kids.add(ksNode((u8*)"dog.png"));
        fileTree.root.kids.add(docs);
        fileTree.root.kids.add(pics);
        fileTree.root.kids.add(ksNode((u8*)"readme.txt"));

        UXView* tcanvas = new UXView(); // the outline sits in a canvas (a native control as a
        treeWin = new UXWindow();       // subview, like the main window's table — not as the root)
        treeWin.open((u8*)"Files", UXGeom.make((i16)600, (i16)90, (i16)240, (i16)320), tcanvas);
        tree = new UXOutlineView();
        tcanvas.addSubview(tree, UXGeom.make((i16)0, (i16)0, (i16)240, (i16)320));
        tree.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        tree.setRowHeight((i16)22);
        tree.addColumn((u8*)"Name", (i16)236);
        tree.setOutlineSource(fileTree);
        tree.reloadData();
        tree.toggleRow((i32)0); // open Documents so the hierarchy is visible at a glance
        treeWin.tree.finalise();
        treeWin.displayAll();
        app.addWindow(treeWin);
        }

    // A third window: a scroll view over a tall list — native scroller on each backend.
    void buildScroll(void)
        {
        UXView* canvas = new UXView();
        scrollWin = new UXWindow();
        scrollWin.open((u8*)"Scroll View", UXGeom.make((i16)600, (i16)430, (i16)240, (i16)200), canvas);
        UXScrollView* sv = new UXScrollView();
        canvas.addSubview(sv, UXGeom.make((i16)0, (i16)0, (i16)240, (i16)200));
        sv.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        sv.setLineHeight((i16)28);
        UXView* doc = sv.document();
        for (i32 i = (i32)0; i < (i32)16; i = i + (i32)1)
            {
            doc.addSubview(KSCard.make(i), UXGeom.make((i16)0, (i16)(i * (i32)28), (i16)236, (i16)28));
            }
        sv.setDocumentHeight((i32)16 * (i32)28);
        scrollWin.tree.finalise();
        scrollWin.displayAll();
        app.addWindow(scrollWin);
        }

    // A fourth window: a split view — a sidebar and a detail pane, divider draggable.
    void buildSplit(void)
        {
        UXView* canvas = new UXView();
        splitWin = new UXWindow();
        splitWin.open((u8*)"Split View", UXGeom.make((i16)860, (i16)90, (i16)380, (i16)220), canvas);
        UXSplitView* split = new UXSplitView();
        canvas.addSubview(split, UXGeom.make((i16)0, (i16)0, (i16)380, (i16)220));
        split.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        split.setDividerPos((i16)110);
        KSPane* left = new KSPane();
        left.tint = (i32)8;
        left.name = (u8*)"Sidebar";
        split.firstPane().addSubview(left, UXGeom.make((i16)0, (i16)0, (i16)110, (i16)220));
        left.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        KSPane* right = new KSPane();
        right.tint = (i32)0;
        right.name = (u8*)"Detail";
        split.secondPane().addSubview(right, UXGeom.make((i16)0, (i16)0, (i16)264, (i16)220));
        right.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        splitWin.tree.finalise();
        splitWin.displayAll();
        app.addWindow(splitWin);
        }

    // A fifth window: the widget showcase — a slider that drives a progress bar, a stepper with a live
    // read-out, a popup, a segmented control and a toolbar.  Native on AppKit/Win32, self-drawn on GEM.
    void buildWidgets(void)
        {
        KSCanvas* canvas = new KSCanvas(); // fills a grey backdrop (GEM has no window fill of its own)
        widgetWin = new UXWindow();
        widgetWin.open((u8*)"Widgets", UXGeom.make((i16)360, (i16)430, (i16)360, (i16)210), canvas);

        UXToolbar* tb = new UXToolbar();
        tb.addItem((u8*)"new", (u8*)"New", (i32)10, (i16)44);
        tb.addItem((u8*)"opn", (u8*)"Open", (i32)20, (i16)44);
        tb.addSeparator();
        tb.addItem((u8*)"del", (u8*)"Delete", (i32)30, (i16)52);
        tb.setAction(&self.onTool);
        canvas.addSubview(tb, UXGeom.make((i16)8, (i16)6, (i16)344, (i16)30));

        UXSegmentedControl* seg = new UXSegmentedControl();
        seg.addSegment((u8*)"Day", (i32)1);
        seg.addSegment((u8*)"Week", (i32)2);
        seg.addSegment((u8*)"Month", (i32)3);
        seg.selectSegment((i32)1);
        seg.setAction(&self.onSeg);
        canvas.addSubview(seg, UXGeom.make((i16)8, (i16)42, (i16)210, (i16)26));

        slider = new UXSlider();
        slider.setRange((i32)0, (i32)100);
        slider.setValue((i32)60);
        slider.setAction(&self.onSlider);
        canvas.addSubview(slider, UXGeom.make((i16)8, (i16)78, (i16)160, (i16)28));

        stepper = new UXStepper();
        stepper.setRange((i32)0, (i32)10);
        stepper.setValue((i32)3);
        stepper.setAction(&self.onStepper);
        canvas.addSubview(stepper, UXGeom.make((i16)180, (i16)78, (i16)20, (i16)28));
        stepVal = new UXLabel();
        stepVal.setText((u8*)"3");
        canvas.addSubview(stepVal, UXGeom.make((i16)204, (i16)84, (i16)16, (i16)16));

        UXPopUpButton* pu = new UXPopUpButton();
        pu.addItem((u8*)"Small", (i32)10);
        pu.addItem((u8*)"Medium", (i32)20);
        pu.addItem((u8*)"Large", (i32)30);
        pu.setAction(&self.onPopup);
        canvas.addSubview(pu, UXGeom.make((i16)232, (i16)78, (i16)120, (i16)24));

        prog = UXProgress.make((i32)100);
        prog.setCompleted((i32)60);
        progBar = new UXProgressBar();
        progBar.setProgress(prog);
        canvas.addSubview(progBar, UXGeom.make((i16)8, (i16)116, (i16)344, (i16)18));

        widgetWin.tree.finalise();
        widgetWin.displayAll();
        app.addWindow(widgetWin);
        }

    // A sixth window: the in-app drag-and-drop board (drag a tile onto the well).
    void buildDragDrop(void)
        {
        UXView* canvas = new UXView();
        dragWin = new UXWindow();
        dragWin.open((u8*)"Drag & Drop", UXGeom.make((i16)380, (i16)210, (i16)320, (i16)150), canvas);
        KSDragBoard* board = new KSDragBoard();
        canvas.addSubview(board, UXGeom.make((i16)0, (i16)0, (i16)320, (i16)150));
        board.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        dragWin.tree.finalise();
        dragWin.displayAll();
        app.addWindow(dragWin);
        }

    // A seventh window: palette colour selection + an editable image well (paint cells with the picked
    // colour, or drag a swatch onto the well to flood it).
    // The toolkit picker's Select/Cancel (GEM only).
    void onColourSelect(UXControl* c)
        {
        pickedColor = colourBoard.curColor();
        self.reportColour();
        app.closeWindowLater(colourWin);
        }
    void onColourCancel(UXControl* c)
        {
        app.closeWindowLater(colourWin);
        }
    void reportColour(void)
        {
        self.say(UXStr.append((u8*)"Colour ", KSColourBoard.hexStr(pickedColor)));
        }
    // The GEM toolkit colour-picker window: the hue/sat wheel + HSV/RGB sliders + Cancel/Select.
    void buildColour(void)
        {
        UXView* canvas = new UXView();
        colourWin = new UXWindow();
        colourWin.open((u8*)"Colour Picker", UXGeom.make((i16)200, (i16)140, (i16)464, (i16)320), canvas);
        colourBoard = new KSColourBoard();
        if (pickedColor != (UXColor*)0)
            {
            colourBoard.seed(pickedColor);
            }
        canvas.addSubview(colourBoard, UXGeom.make((i16)0, (i16)0, (i16)464, (i16)320)); // fills the whole window grey
        colourBoard.setup(canvas);                                                       // wheel + slider child views
        UXButton* cancel = new UXButton();
        cancel.setTitle((u8*)"Cancel");
        cancel.setAction(&self.onColourCancel);
        canvas.addSubview(cancel, UXGeom.make((i16)278, (i16)286, (i16)84, (i16)26));
        UXButton* select = new UXButton();
        select.setTitle((u8*)"Select");
        select.setAction(&self.onColourSelect);
        canvas.addSubview(select, UXGeom.make((i16)370, (i16)284, (i16)84, (i16)28));
        colourWin.tree.finalise();
        colourWin.displayAll();
        app.addWindow(colourWin);
        }

    // The toolkit font-chooser's Select/Cancel (GEM/Win32 only).
    void onFontSelect(UXControl* c)
        {
        pickedFont = fontBoard.curFont();
        self.reportFont();
        app.closeWindowLater(fontWin);
        }
    void onFontCancel(UXControl* c)
        {
        app.closeWindowLater(fontWin);
        }
    void reportFont(void)
        {
        self.say(UXStr.append((u8*)"Font ", pickedFont.description()));
        }
    // The GEM/Win32 toolkit font-chooser window: family list + size stepper + bold/italic + preview + Cancel/Select.
    void buildFont(void)
        {
        UXView* canvas = new UXView();
        fontWin = new UXWindow();
        fontWin.open((u8*)"Font Chooser", UXGeom.make((i16)210, (i16)130, (i16)480, (i16)348), canvas);
        fontBoard = new KSFontBoard();
        if (pickedFont != (UXFont*)0)
            {
            fontBoard.seed(pickedFont);
            }
        canvas.addSubview(fontBoard, UXGeom.make((i16)0, (i16)0, (i16)480, (i16)348));
        fontBoard.setup(canvas); // list + stepper + checkbox child views
        UXButton* cancel = new UXButton();
        cancel.setTitle((u8*)"Cancel");
        cancel.setAction(&self.onFontCancel);
        canvas.addSubview(cancel, UXGeom.make((i16)294, (i16)310, (i16)84, (i16)26));
        UXButton* select = new UXButton();
        select.setTitle((u8*)"Select");
        select.setAction(&self.onFontSelect);
        canvas.addSubview(select, UXGeom.make((i16)386, (i16)308, (i16)84, (i16)28));
        fontWin.tree.finalise();
        fontWin.displayAll();
        app.addWindow(fontWin);
        }

    // The rule editor: rule rows over UXPredicate, filtering the same eight records the main window
    // tables.  Nothing here is backend-specific — popups, fields and a table, so it lands on all three.
    void buildRules(void)
        {
        UXView* canvas = new UXView();
        rulesWin = new UXWindow();
        rulesWin.open((u8*)"Rules", UXGeom.make((i16)240, (i16)150, (i16)490, (i16)424), canvas);
        rulesBoard = new KSRulesBoard();
        canvas.addSubview(rulesBoard, UXGeom.make((i16)0, (i16)0, (i16)490, (i16)424));
        rulesBoard.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        rulesBoard.setup(canvas); // popups + fields + the result table
        UXButton* apply = new UXButton();
        apply.setTitle((u8*)"Apply");
        apply.setAction(&self.onRulesApply);
        canvas.addSubview(apply, UXGeom.make((i16)390, (i16)390, (i16)84, (i16)26));
        apply.setAutoresizeMask((i32)UX_ANCHOR_RIGHT | (i32)UX_ANCHOR_BOTTOM);
        rulesWin.tree.finalise();
        rulesWin.displayAll();
        app.addWindow(rulesWin);
        }
    // The board filters live on every edit; Apply is the explicit re-run (and the GEM path where a
    // field may not report each keystroke).
    void onRulesApply(UXControl* c)
        {
        rulesBoard.applyRules();
        self.say(UXStr.append(UXStr.fromInt(ksMatchN), (u8*)" rows match the rules"));
        }

    // The line breaker with a face on it: a paragraph re-flowed to the window, measured in the font it
    // is drawn in.  Resize the window and the wrap follows; the stepper re-flows at another size.
    // ---- the vector window: curves, a thick stroke with caps, and a radial fill ------------------
    void buildVector(void)
        {
        UXView* canvas = new UXView();
        vectorWin = new UXWindow();
        vectorWin.open((u8*)"Vectors", UXGeom.make((i16)200, (i16)140, (i16)400, (i16)440), canvas);
        vectorBoard = new KSVectorBoard();
        canvas.addSubview(vectorBoard, UXGeom.make((i16)0, (i16)0, (i16)400, (i16)440));
        vectorBoard.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        vectorBoard.build();

        // Live controls, so the stroke width and the band count can be seen doing their work rather
        // than described: drag the width down to 2 and the joins stop mattering, up to 40 and they
        // are the only thing holding the corners together.
        UXLabel* wl = new UXLabel();
        canvas.addSubview(wl, UXGeom.make((i16)16, (i16)392, (i16)80, (i16)20));
        wl.setText((u8*)"width");
        wl.setAutoresizeMask((i32)UX_ANCHOR_BOTTOM);
        vecWidth = new UXStepper();
        canvas.addSubview(vecWidth, UXGeom.make((i16)70, (i16)390, (i16)22, (i16)24));
        vecWidth.setRange((i32)1, (i32)40);
        vecWidth.setValue((i32)16);
        vecWidth.setAction(&self.onVecWidth);
        vecWidth.setAutoresizeMask((i32)UX_ANCHOR_BOTTOM);

        UXLabel* bl = new UXLabel();
        canvas.addSubview(bl, UXGeom.make((i16)115, (i16)392, (i16)80, (i16)20));
        bl.setText((u8*)"bands");
        bl.setAutoresizeMask((i32)UX_ANCHOR_BOTTOM);
        vecBands = new UXStepper();
        canvas.addSubview(vecBands, UXGeom.make((i16)205, (i16)390, (i16)22, (i16)24));
        vecBands.setRange((i32)2, (i32)48);
        vecBands.setValue((i32)24);
        // A stepper is a narrow up/down control: 22px is what the drawn one on GEM needs and what the
        // native NSStepper/updown occupies anyway.  It was 60, which looked stretched on GEM (where
        // the toolkit draws it at the size it is given) and normal on macOS (where the OS control
        // sizes itself and quietly ignored the frame).
        vecBands.setAction(&self.onVecBands);
        vecBands.setAutoresizeMask((i32)UX_ANCHOR_BOTTOM);

        vecHull = new UXCheckbox();
        canvas.addSubview(vecHull, UXGeom.make((i16)250, (i16)392, (i16)140, (i16)20));
        vecHull.setTitle((u8*)"show flattening");
        vecHull.setAction(&self.onVecHull);
        vecHull.setAutoresizeMask((i32)UX_ANCHOR_BOTTOM);

        vectorWin.tree.finalise();
        vectorWin.displayAll();
        app.addWindow(vectorWin);
        }
    void onVecWidth(UXControl* c)
        {
        vectorBoard.setWidth(vecWidth.intValue());
        }
    void onVecBands(UXControl* c)
        {
        vectorBoard.setBands(vecBands.intValue());
        }
    void onVecHull(UXControl* c)
        {
        vectorBoard.setHull(vecHull.isChecked());
        }

    void buildText(void)
        {
        UXView* canvas = new UXView();
        textWin = new UXWindow();
        textWin.open((u8*)"Text", UXGeom.make((i16)260, (i16)170, (i16)440, (i16)300), canvas);
        textBoard = new KSTextBoard();
        canvas.addSubview(textBoard, UXGeom.make((i16)0, (i16)0, (i16)440, (i16)300));
        textBoard.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT); // re-wrap on resize
        textBoard.setup(canvas);
        textWin.tree.finalise();
        textWin.displayAll();
        app.addWindow(textWin);
        }

    // ---- the recorder: capture the event stream, then play it back ------------------------------
    // The tap sees every event the run loop dispatches (UXApplication.setEventTap), so what is
    // captured is exactly what the app acted on — clicks that selected a row, keystrokes that went
    // into the field, wheel notches that scrolled.  Replay pushes the copies back in through the
    // window's own dispatch, BELOW the tap, so a replay is never itself recorded.
    void onRecTap(UXEvent* e)
        {
        if (recorder != (UXEventRecorder*)0)
            {
            recorder.record(e, gDriver.nowMs());
            }
        }
    void recSay(u8* s)
        {
        if (recStatus != (UXLabel*)0)
            {
            recStatus.setText(s);
            }
        }
    void onRecStart(UXControl* c)
        {
        recorder.start(gDriver.nowMs());
        app.setEventTap(&self.onRecTap);
        self.recSay((u8*)"recording — click rows, scroll, type, toggle");
        }
    void onRecStop(UXControl* c)
        {
        recorder.stop();
        app.setEventTap((callback void(UXEvent * e))0);
        u8* t = UXStr.append(UXStr.fromInt(recorder.count()), (u8*)" events over ");
        t = UXStr.append(t, UXStr.fromInt(recorder.durationMs()));
        self.recSay(UXStr.append(t, (u8*)" ms — press Replay"));
        }
    // The sink: hand each recorded event back to the window that owns these widgets.
    void onRecPlayback(UXEvent* e)
        {
        if (recWin == (UXWindow*)0 || !recWin.isOpen())
            {
            return;
            }
        if (e.kind == (u8)UXEventMouseDown)
            {
            recWin.dispatchMouse(e);
            }
        else if (e.kind == (u8)UXEventKeyDown)
            {
            recWin.dispatchKey(e);
            }
        else if (e.kind == (u8)UXEventWheel)
            {
            recWin.dispatchWheel(e);
            }
        else if (e.kind == (u8)UXEventSelected)
            {
            // The selection as an outcome — on Win32 the click that made it never reached the
            // toolkit, so this is what the recording holds.  realizeTree pushes it into the control.
            UXTableView* tv = (UXTableView* ?)recWin.tree.viewAt((u16)e.a);
            if (tv != (UXTableView*)0)
                {
                tv.deselectAllRows();
                UXIndexSet* sel = (UXIndexSet* ?)e.data;     // every row that was selected
                if (sel != (UXIndexSet*)0)
                    {
                    for (i32 r = sel.firstIndex(); r >= (i32)0; r = sel.indexGreaterThan(r))
                        {
                        tv.setRowSelected(r, true);
                        }
                    }
                else if (e.b >= (i32)0)
                    {
                    tv.setRowSelected(e.b, true);
                    }
                }
            }
        else if (e.kind == (u8)UXEventTextChanged)
            {
            // Put the typed text back.  setText updates the buffer AND the native control on the next
            // realize (SetWindowTextA / ux_ak_update_field), which is what makes it visible.
            UXTextField* tf = (UXTextField* ?)recWin.tree.viewAt((u16)e.a);
            String* tp = (String* ?)e.data;
            if (tf != (UXTextField*)0 && tp != (String*)0)
                {
                tf.setText(tp.cString());
                }
            }
        else if (e.kind == (u8)UXEventScrolled)
            {
            // Put the view back where the recording left it.  The drag that scrolled it was modal
            // and unrecordable; this is its outcome, replayed directly onto the view it names.
            UXScrollView* sv = (UXScrollView* ?)recWin.tree.viewAt((u16)e.a);
            if (sv != (UXScrollView*)0)
                {
                sv.scrollTo((i16)e.b);
                }
            }
        }
    void onRecReplay(UXControl* c)
        {
        if (recorder.count() == (i32)0)
            {
            self.recSay((u8*)"nothing recorded yet");
            return;
            }
        recorder.replay(&self.onRecPlayback);
        u8* t = UXStr.append((u8*)"replayed ", UXStr.fromInt(recorder.count()));
        self.recSay(UXStr.append(t, (u8*)" events"));
        // NOT displayAll: on GEM that asks gemd for a redraw, which arrives as a later message — so
        // the replayed changes only appeared once some other event happened to pump the loop.  The
        // replayed dispatches already marked what changed; the run loop repaints after this action
        // returns, and realizeTree pushes the model back into the native controls on the way.
        }
    void onRecClear(UXControl* c)
        {
        recorder.clear();
        self.recSay((u8*)"cleared");
        }

    void buildRecord(void)
        {
        UXView* canvas = new KSCanvas();
        recWin = new UXWindow();
        recWin.open((u8*)"Recorder", UXGeom.make((i16)150, (i16)120, (i16)460, (i16)380), canvas);
        if (recorder == (UXEventRecorder*)0)
            {
            recorder = new UXEventRecorder();
            }

        UXButton* rec = new UXButton();
        rec.setTitle((u8*)"Record");
        rec.setAction(&self.onRecStart);
        canvas.addSubview(rec, UXGeom.make((i16)16, (i16)16, (i16)84, (i16)26));
        UXButton* stop = new UXButton();
        stop.setTitle((u8*)"Stop");
        stop.setAction(&self.onRecStop);
        canvas.addSubview(stop, UXGeom.make((i16)108, (i16)16, (i16)84, (i16)26));
        UXButton* play = new UXButton();
        play.setTitle((u8*)"Replay");
        play.setAction(&self.onRecReplay);
        canvas.addSubview(play, UXGeom.make((i16)200, (i16)16, (i16)84, (i16)26));
        UXButton* clr = new UXButton();
        clr.setTitle((u8*)"Clear");
        clr.setAction(&self.onRecClear);
        canvas.addSubview(clr, UXGeom.make((i16)292, (i16)16, (i16)84, (i16)26));

        // The things worth recording: a multi-select table that also scrolls, a toggle, a field.
        recTable = new UXTableView();
        canvas.addSubview(recTable, UXGeom.make((i16)16, (i16)56, (i16)424, (i16)176));
        recTable.setAutoresizeMask((i32)UX_FLEX_WIDTH | (i32)UX_FLEX_HEIGHT);
        recTable.setAllowsMultipleSelection(true);
        recTable.setRowHeight((i16)22);
        recTable.addColumn((u8*)"Name", (i16)200);
        recTable.addColumn((u8*)"Size", (i16)70);
        recTable.addColumn((u8*)"Kind", (i16)140);
        recTable.setDataSource(self);
        recTable.setDelegate(self);
        recTable.reloadData();

        recCheck = new UXCheckbox();
        recCheck.setTitle((u8*)"A toggle to flip");
        canvas.addSubview(recCheck, UXGeom.make((i16)16, (i16)244, (i16)200, (i16)21));
        recCheck.setAutoresizeMask((i32)UX_ANCHOR_BOTTOM);
        recField = new UXTextField();
        recField.setPlaceholder((u8*)"type here…");
        canvas.addSubview(recField, UXGeom.make((i16)16, (i16)272, (i16)220, (i16)22));
        recField.setAutoresizeMask((i32)UX_ANCHOR_BOTTOM);
        recStatus = new UXLabel();
        recStatus.setText((u8*)"press Record, then use the widgets above");
        canvas.addSubview(recStatus, UXGeom.make((i16)16, (i16)306, (i16)424, (i16)16));
        recStatus.setAutoresizeMask((i32)UX_ANCHOR_BOTTOM | (i32)UX_FLEX_WIDTH);

        recWin.tree.finalise();
        recWin.displayAll();
        app.addWindow(recWin);
        }

    void buildMenu(void)
        {
        UXMenuBar* bar = new UXMenuBar();
        UXMenu* demo = bar.addMenu((u8*)"Demo");
        demo.addItem((u8*)"About", &self.mAbout);
        demo.addSeparator();
        demo.addItem((u8*)"Quit", &self.mQuit);
        UXMenu* edit = bar.addMenu((u8*)"Edit");
        edit.addItem((u8*)"Clear Field", &self.mClear);
        // The Windows menu: pick a name to open that window (first time) or raise it (thereafter), so the
        // secondary windows don't all clutter the screen at launch.
        UXMenu* windows = bar.addMenu((u8*)"Windows");
        windows.addItem((u8*)"Kitchen Sink", &self.mWinMain);
        windows.addItem((u8*)"Widgets", &self.mWinWidgets);
        windows.addItem((u8*)"Drag & Drop", &self.mWinDrag);
        windows.addItem((u8*)"Colours", &self.mWinColour);
        windows.addItem((u8*)"Fonts", &self.mWinFont);
        windows.addItem((u8*)"Vectors", &self.mWinVector);
        windows.addItem((u8*)"Rules", &self.mWinRules);
        windows.addItem((u8*)"Text", &self.mWinText);
        windows.addItem((u8*)"Recorder", &self.mWinRecord);
        windows.addItem((u8*)"Files", &self.mWinFiles);
        windows.addItem((u8*)"Scroll View", &self.mWinScroll);
        windows.addItem((u8*)"Split View", &self.mWinSplit);
        app.setMenuBar(bar);
        }

    // The main kitchen-sink window — its own builder so the Windows menu can reopen it after a close.
    void buildMain(void)
        {
        KSCanvas* canvas = new KSCanvas();
        win = new UXWindow();
        win.open((u8*)"UXKit Kitchen Sink", UXGeom.make((i16)120, (i16)90, (i16)460, (i16)420), canvas);
        app.addWindow(win);
        self.buildHeader(canvas);
        self.buildOptions(canvas);
        self.buildTable(canvas);
        self.buildButtons(canvas);
        win.tree.finalise();
        win.displayAll();
        }

    i32 applicationDidStart(UXApplication* a)
        {
        app = a;
        self.fillData();
        self.buildMain();
        self.buildMenu();
        // The other windows (Widgets, Files, Scroll View, Split View) open on demand from the Windows
        // menu — see mWin* — so the desktop starts uncluttered with just the main window.
        Stdio.printf("kitchen sink up — resize the window, click widgets, use the Windows menu\n");
        return (i32)0;
        }
    }
