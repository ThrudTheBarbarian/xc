// UXView.xc — a view IS a GEM object.
//
// The view does not own a rectangle and a list of children; it owns an INDEX into
// an UXViewTree, and the OBJECT at that index is the truth.  Geometry, hierarchy,
// visibility and state all live in the OBJECT, because that is what the AES reads.
//
// A plain container is a G_IBOX (invisible).  A view that draws is a G_USERDEF,
// and the AES calls back into drawRect through objc_set_userdraw.  Standard
// controls are their real GEM types (G_BUTTON, G_FIELD, ...) and GEM draws them —
// they cost us nothing.

#import "Array.xc"
#import "UXGem.xc"
#import "UXGeometry.xc"
#import "UXResponder.xc"
#import "UXViewTree.xc"
#import "UXGraphics.xc"

// Raised by setNeedsDisplay, lowered by the run loop after it repaints.
bool gNeedsDisplay;

class UXView : UXResponder
    {
    weak : UXViewTree* owner; // the tree we live in (it holds us, so weak)
    u16 index;                // our slot in that tree
    weak : UXView* superview;
    Array* subviews;    // strong: a view owns its children
    i32 autoresizeMask; // springs & struts (UX_ANCHOR_* | UX_FLEX_*); 0 = pinned top-left

    void init(void)
        {
        super.init();
        owner = (UXViewTree*)0;
        index = (u16)0;
        superview = (UXView*)0;
        subviews = new Array();
        autoresizeMask = (i32)0;
        }

    // The neutral kind this view realizes as.  Override in a subclass:
    //   UXButton -> UXKindButton, UXTextField -> UXKindField, a container -> UXKindBox.
    // The base is UXKindView: a custom-drawn view whose drawRect paints it.
    UXKind kind(void)
        {
        return UXKindView;
        }

    // Attach to a tree, creating the backing object.  Called by the tree/window, not by
    // app code.
    void attachTo(UXViewTree* t, UXRect frame)
        {
        owner = t;
        index = t.append((i32)self.kind(), frame, self);
        }

    // Attach to an OBJECT that ALREADY exists — the .rsc path.  The resource
    // supplied the type, the frame, the flags and the state; we supply behaviour.
    void adoptObject(UXViewTree* t, u16 i)
        {
        owner = t;
        index = i;
        t.bind(i, self);
        }

    // ---- geometry: the OBJECT is the truth ---------------------------------

    // A view with no tree has no frame.  `owner` is weak: it is nil before attachTo(),
    // and it BECOMES nil if the tree is released out from under us — so this is a guard
    // against a live hazard, not just against misuse.  (Without it, bounds() on an
    // unattached view is a null-receiver call: PC=0, PREFETCH-ABORT.)
    UXRect frame(void)
        {
        if (owner == (UXViewTree*)0)
            {
            return UXGeom.make((i16)0, (i16)0, (i16)0, (i16)0);
            }
        return owner.frameOf(index);
        }

    void setFrame(UXRect f)
        {
        owner.setFrameOf(index, f);
        self.setNeedsDisplay();
        }

    // Bounds are the frame at the origin — drawRect works in bounds coordinates.
    UXRect bounds(void)
        {
        UXRect f = self.frame();
        return UXGeom.make((i16)0, (i16)0, f.w, f.h);
        }

    UXRect absoluteFrame(void)
        {
        if (owner == (UXViewTree*)0)
            {
            return UXGeom.make((i16)0, (i16)0, (i16)0, (i16)0);
            }
        return owner.absoluteFrame(index);
        }

    // ---- hierarchy ----------------------------------------------------------

    // The frame is passed in: a view has no tree — and so no frame — until it is
    // attached to one.
    void addSubview(UXView* v, UXRect f)
        {
        v.attachTo(owner, f);
        owner.addChild(index, v.index);
        v.superview = self;
        v.setNextResponder(self); // the responder chain follows the views
        subviews.add(v);
        self.setNeedsDisplay();
        }

    // Detach from the tree AND from the parent's subview list.  Both halves
    // matter: addSubview does `subviews.add(v)`, so a removal that only
    // unhooked the tree left the parent holding a strong reference to a view
    // that is no longer in it — a leak, and worse, every walk over `subviews`
    // (drawing, the autoresize pass) then visits a view whose tree slot is
    // gone.
    void removeFromSuperview(void)
        {
        if (superview == (UXView*)0)
            {
            return;
            }
        UXView* p = superview;
        p.owner.removeChild(p.index, index);
        for (u16 i = (u16)0; i < p.subviews.count(); i = i + (u16)1)
            {
            if ((UXView* ?)p.subviews.get(i) == self)
                {
                p.subviews.removeAt(i);
                break;
                }
            }
        p.setNeedsDisplay();
        superview = (UXView*)0;
        }

    // Empty this view.  Removing children one at a time by index is the trap
    // here — the indices shift underneath — so each child is asked to detach
    // itself, which keeps the tree and the array in step by construction.  The
    // count guard is a backstop: a child whose superview is not us would
    // otherwise spin forever.
    void removeAllSubviews(void)
        {
        while (subviews.count() > (u16)0)
            {
            u16 before = subviews.count();
            ((UXView* ?)subviews.get((u16)0)).removeFromSuperview();
            if (subviews.count() >= before)
                {
                subviews.removeAt((u16)0);
                }
            }
        self.setNeedsDisplay();
        }

    // ---- visibility / state, straight through to the OBJECT ------------------

    bool isHidden(void)
        {
        return owner.hiddenOf(index);
        }
    void setHidden(bool h)
        {
        owner.setHiddenOf(index, h);
        self.setNeedsDisplay();
        }

    bool isEnabled(void)
        {
        return owner.enabledOf(index);
        }
    void setEnabled(bool e)
        {
        owner.setEnabledOf(index, e);
        self.setNeedsDisplay();
        }

    // Springs & struts: which edges this view stays glued to, and which dimensions it may stretch,
    // as its window resizes (UX_ANCHOR_* | UX_FLEX_*).  A native-resize backend (AppKit) tracks the
    // frame LIVE during a drag; a backend without native autoresizing gets the SAME behaviour from
    // resizeSubviews below.  Stored here (for the neutral layout) AND handed to the driver (for the
    // native one).  Set after attach.
    void setAutoresizeMask(i32 mask)
        {
        autoresizeMask = mask;
        if (owner != (UXViewTree*)0)
            {
            owner.setAutoresizeOf(index, mask);
            }
        }

    // One axis of the springs & struts solve, as two value-returning halves (xtc dislikes `&` on a
    // local passed to a static method).  A child at `pos`/`size` in a parent that went from `oldP` to
    // `newP`: flexible springs share the delta (proportional when both the leading margin and the size
    // flex); an all-fixed child stays pinned to the leading edge and the trailing margin absorbs it.
    static i32 springPos(i32 pos, i32 size, i32 oldP, i32 newP, bool leadFlex, bool sizeFlex)
        {
        i32 delta = newP - oldP;
        if (leadFlex && sizeFlex)
            {
            i32 total = pos + size;
            if (total <= (i32)0)
                {
                total = (i32)1;
                }
            return pos + delta * pos / total;
            }
        if (leadFlex)
            {
            return pos + delta;
            }
        return pos; // fixed leading margin
        }
    static i32 springSize(i32 pos, i32 size, i32 oldP, i32 newP, bool leadFlex, bool sizeFlex)
        {
        i32 delta = newP - oldP;
        i32 nSize = size;
        if (leadFlex && sizeFlex)
            {
            i32 total = pos + size;
            if (total <= (i32)0)
                {
                total = (i32)1;
                }
            nSize = size + (delta - delta * pos / total);
            }
        else if (sizeFlex)
            {
            nSize = size + delta;
            }
        if (nSize < (i32)0)
            {
            nSize = (i32)0;
            }
        return nSize;
        }

    // Reposition my subviews for a change in MY content size, per each child's mask, and recurse so a
    // nested layout follows.  A backend without native autoresizing calls this on resize (UXWindow);
    // a native one does it itself and skips this.  Reads the mask flags exactly as the AppKit driver
    // maps them, so both backends lay a masked view out the same way.
    void resizeSubviews(i32 oldW, i32 oldH, i32 newW, i32 newH)
        {
        UXRect f = UXGeom.zero(); // pinned at function scope (xtc requires it for a struct local)
        for (Object* o in subviews)
            {
            UXView* c = (UXView* ?)o;
            if (c != (UXView*)0)
                {
                i32 m = c.autoresizeMask;
                f = c.frame();
                bool hLead = (m & (i32)UX_ANCHOR_RIGHT) != (i32)0 && (m & (i32)UX_ANCHOR_LEFT) == (i32)0;
                bool hSize = (m & (i32)UX_FLEX_WIDTH) != (i32)0 || ((m & (i32)UX_ANCHOR_LEFT) != (i32)0 && (m & (i32)UX_ANCHOR_RIGHT) != (i32)0);
                bool vLead = (m & (i32)UX_ANCHOR_BOTTOM) != (i32)0 && (m & (i32)UX_ANCHOR_TOP) == (i32)0;
                bool vSize = (m & (i32)UX_FLEX_HEIGHT) != (i32)0 || ((m & (i32)UX_ANCHOR_TOP) != (i32)0 && (m & (i32)UX_ANCHOR_BOTTOM) != (i32)0);
                i32 nx = UXView.springPos((i32)f.x, (i32)f.w, oldW, newW, hLead, hSize);
                i32 nw = UXView.springSize((i32)f.x, (i32)f.w, oldW, newW, hLead, hSize);
                i32 ny = UXView.springPos((i32)f.y, (i32)f.h, oldH, newH, vLead, vSize);
                i32 nh = UXView.springSize((i32)f.y, (i32)f.h, oldH, newH, vLead, vSize);
                i32 cOldW = (i32)f.w;
                i32 cOldH = (i32)f.h;
                // Where the driver autoresizes NATIVELY (AppKit: real NSView masks), leave its
                // controls alone — but a CUSTOM-DRAWN view has no NSView to track, so its frame is
                // ours to update or it never changes size at all.  That is not cosmetic: drawRect
                // works in bounds(), so a view that lays its own content out (wrapped text) was
                // still using the width it was born with.  Recurse either way — a native control
                // can hold custom views.
                if (!gDriver.driverAutoresizes() || c.kind() == UXKindView)
                    {
                    c.setFrame(UXGeom.make((i16)nx, (i16)ny, (i16)nw, (i16)nh));
                    }
                c.resizeSubviews(cOldW, cOldH, nw, nh);
                }
            }
        }

    // ---- drawing -------------------------------------------------------------

    // Override this.  It is called BY THE AES, during objc_draw's own traversal,
    // inside the AES's clip — see objc_set_userdraw.  Coordinates are absolute.
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        }

    // Mark dirty.  Draws NOTHING: it records a RECT on the tree, and the run loop
    // repaints once per iteration.
    //
    // The rect matters.  A global "something changed" flag repaints the WHOLE WINDOW,
    // which is invisible for a button and exactly backwards for a text editor: one
    // character typed would redraw every view and damage the entire window.  A table
    // scrolling a single row would repaint the world.
    //
    // The rect goes on the TREE, not on a window: UXView already holds its tree, and
    // an UXView -> UXWindow import would be a cycle.  gNeedsDisplay survives as the
    // cheap "is ANY window dirty?" test the run loop checks first.
    void setNeedsDisplay(void)
        {
        self.setNeedsDisplayInRect(self.absoluteFrame());
        }

    // Redraw only part of me — what a text view does when one line changes.
    // `abs` is in ABSOLUTE (screen) coordinates, as absoluteFrame() returns.
    void setNeedsDisplayInRect(UXRect abs)
        {
        if (owner != (UXViewTree*)0)
            {
            owner.markDirty(abs);
            }
        gNeedsDisplay = true;
        }

    // ---- hit-testing ---------------------------------------------------------
    // Deliberately NOT implemented here: objc_find already does it, correctly,
    // depth-first, honouring OF_HIDETREE.  See UXViewTree.hitTest.
    }

    // An INPUT SHIELD: a transparent view that takes every press in its area and
    // hands it to the toolkit, instead of letting the native controls underneath
    // have it.
    //
    // WHY THIS HAS TO BE A NATIVE THING.  On most backends a plain UXView is DRAWN,
    // not realized: there is one native view per WINDOW and every control is a flat
    // child of it.  So putting a view "on top" in the toolkit's own tree intercepts
    // nothing — the platform hit-tests its own hierarchy first, routes the click to
    // the NSButton (or HWND, or GtkWidget) under the pointer, and the toolkit never
    // hears about it.  Ordering in the shadow tree only decides who wins AFTER the
    // press has already reached the toolkit.
    //
    // A design surface needs the inversion: real widgets, realized and drawn by the
    // real backend so what the designer sees is what will run, but a click that
    // SELECTS one rather than pressing it.  The shield is where that inversion
    // lives, and keeping it in one named view means the rest of a toolkit client
    // never has to think about it.
    //
    // The press arrives at the shield's own mouseDown in window coordinates, like
    // any other; it is the ordinary responder path from there on.
    class UXShieldView : UXView
    {
    void init(void)
        {
        super.init();
        }
    UXKind kind(void)
        {
        return UXKindShield;
        }

    // It takes presses but never the keyboard: the keyboard belongs to whatever
    // the surrounding editor is typing into.
    bool acceptsFirstResponder(void)
        {
        return false;
        }
    }
