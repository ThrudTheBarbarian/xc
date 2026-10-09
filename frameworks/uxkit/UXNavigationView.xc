// UXNavigationView.xc — a sequence of panes laid out SIDE BY SIDE, so a navigation sequence (an
// iOS/Android push stack) can be seen all at once while it is designed.
//
// Neutral: the panes are plain container views a client fills, exactly as a split view's are.  Each
// pane takes an equal share of the view's width and the full height, so a two-step sequence reads as
// two columns and a three-step one as three.  A child's `slot` attribute names the pane it goes in
// (0-based); the loader and the editor route it there (UXRsc.childParent), the same way a split
// view's or a tab view's `slot` works.
#import "UXView.xc"
#import "UXGraphics.xc"

#define UX_NAV_MIN_PANE 60 // no pane is ever laid out narrower than this

class UXNavigationView : UXView
    {
    Array<UXView>* panes;
    i32 paneCount;

    void init(void)
        {
        super.init();
        panes = new Array();
        paneCount = (i32)2;
        }
    UXKind kind(void)
        {
        return UXKindView;
        }

    // How many panes the sequence has (the `panes=N` attribute).
    void setPaneCount(i32 n)
        {
        if (n < (i32)1)
            {
            n = (i32)1;
            }
        paneCount = n;
        self.ensurePanes();
        self.layoutPanes();
        self.setNeedsDisplay();
        }
    i32 count(void)
        {
        return paneCount;
        }
    // The i-th pane, made on demand (the loader asks for a slot's pane before any child is built).
    UXView* paneAt(i32 i)
        {
        if (i < (i32)0)
            {
            i = (i32)0;
            }
        self.ensurePanes();
        if (i >= (i32)panes.count())
            {
            return (UXView*)0;
            }
        return (UXView* ?)panes.get((u32)i);
        }

    void ensurePanes(void)
        {
        if (owner == (UXViewTree*)0)
            {
            return; // not attached yet: attachTo makes them
            }
        while ((i32)panes.count() < paneCount)
            {
            UXView* p = new UXView();
            self.addSubview(p, UXGeom.make((i16)0, (i16)0, (i16)1, (i16)1));
            panes.add(p);
            }
        }
    void attachTo(UXViewTree* t, UXRect frame)
        {
        super.attachTo(t, frame);
        self.ensurePanes();
        self.layoutPanes();
        }
    // Equal columns across the width, full height.
    void layoutPanes(void)
        {
        UXRect f = self.frame();
        i32 n = paneCount > (i32)0 ? paneCount : (i32)1;
        i32 w = (i32)f.w / n;
        if (w < (i32)UX_NAV_MIN_PANE)
            {
            w = (i32)UX_NAV_MIN_PANE;
            }
        for (i32 i = (i32)0; i < (i32)panes.count(); i = i + (i32)1)
            {
            UXView* p = (UXView* ?)panes.get((u32)i);
            owner.setFrameOf(p.index, UXGeom.make((i16)(i * w), (i16)0, (i16)w, f.h));
            }
        }
    void resizeSubviews(i32 oldW, i32 oldH, i32 newW, i32 newH)
        {
        self.layoutPanes();
        }
    }
