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
    bool ownSurface;    // paints in its own native surface where the backend can make one

    void init(void)
        {
        super.init();
        owner = (UXViewTree*)0;
        index = (u16)0;
        superview = (UXView*)0;
        subviews = new Array();
        autoresizeMask = (i32)0;
        ownSurface = false;
        }

    // Ask this view to paint in its OWN SURFACE: its subtree is drawn as a layer that starts empty
    // (a clearRect in it erases only its own ink, never what is under it) and lands OVER a GL map.
    // On AppKit it is a transparency layer in the window's one 2-D pass; a backend without one
    // declines and draws the view inline, exactly as if this were never called.  So the call is
    // safe on every backend.
    //
    // Set it BEFORE the view is added to a parent: the choice becomes the view's KIND, and a
    // node's kind is fixed when it is appended.  A surface view tracks its frame the way a
    // custom-drawn view does, so it wants springs and struts like one.
    void setOwnSurface(bool on)
        {
        ownSurface = on;
        if (owner != (UXViewTree*)0)
            {
            owner.setPeerOf(index, (pointer)self); // the backend keys the surface on the view
            }
        }
    bool paintsInOwnSurface(void)
        {
        return ownSurface;
        }

    // The neutral kind this view realizes as.  Override in a subclass:
    //   UXButton -> UXKindButton, UXTextField -> UXKindField, a container -> UXKindBox.
    // The base is UXKindView: a custom-drawn view whose drawRect paints it — or UXKindSurface
    // when the view has asked to paint in its own surface.
    UXKind kind(void)
        {
        return ownSurface ? UXKindSurface : UXKindView;
        }

    // True while this view OWNS A GL CONTEXT and is therefore rendered by GL rather than
    // by drawRect.  False here, and true only on UXGLView after a context was made.
    //
    // The question is deliberately "does it own a context" and not "is it a GL view": a
    // backend with no GL (glKind() NONE) must still get a picture, and the way it gets one
    // is drawRect.  So a UXGLView on GEM draws its software fallback like any other view,
    // and the same view on a backend with a context skips drawRect entirely.  ux_userdraw
    // is where that is decided, so the two renderers can never both run.
    bool ownsGL(void)
        {
        return false;
        }

    // Attach to a tree, creating the backing object.  Called by the tree/window, not by
    // app code.
    void attachTo(UXViewTree* t, UXRect frame)
        {
        owner = t;
        index = t.append((i32)self.kind(), frame, self);
        if (ownSurface)
            {
            // The backend keys the native surface on the view, so a surface view registers its
            // peer here the way a control does when it sets an action — and it must, because set
            // before the view was attached the peer was set on the previous (absent) tree.
            t.setPeerOf(index, (pointer)self);
            }
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
                if (!gDriver.driverAutoresizes() || c.kind() == UXKindView || c.kind() == UXKindSurface)
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

// A view that OWNS A GL CONTEXT.  An app subclasses this for the map, the charts, anything
// it draws itself with GL, and the toolkit then treats it as one more view in the tree: a
// frame, springs and struts, siblings, z-order, and mouse events, which the TOOLKIT routes
// (a GL view is not a native view, so nothing is stolen from the toolkit's own hit-test).
//
// What it is NOT is a GL windowing toolkit.  There is no loop here, no frame callback and no
// swap of its own: presentGL is called from the app's own turn and the driver paces it.  A
// GL view with its own requestAnimationFrame would be a second clock against the window's,
// and two clocks in one window tear.  The rule the seam rests on is that the driver owns the
// ORDER of the two surfaces and the PACING of the frame.
//
// One order matters and it is the surface before the context: the backend makes the SURFACE
// when it realizes the tree (an NSOpenGLView child, a GtkGLArea child), and makeGL binds the
// context to it.  So makeGL after the window is open — and it forces a realize itself, so a
// caller that gets there first is not left with a half-made view.
class UXGLView : UXView
    {
    pointer glCtx; // the backend's opaque context; 0 = none.  Never dereferenced here.

    void init(void)
        {
        super.init();
        glCtx = (pointer)0;
        }

    UXKind kind(void)
        {
        return UXKindGLView;
        }
    bool ownsGL(void)
        {
        return glCtx != (pointer)0;
        }

    // What the RENDERER is handed.  Opaque: GL.xc passes it back to the driver and never
    // reads through it, which is what keeps the platform's drawable, resize and swap the
    // driver's business rather than the renderer's.
    pointer glContext(void)
        {
        return glCtx;
        }
    // Which GL this backend offers — the answer a renderer needs before it can load a single
    // entry point.  UX_GL_NONE means the view will be drawn by drawRect instead.
    i32 glKind(void)
        {
        return gDriver.glKind();
        }

    // Bind a context to this view.  False where the backend has no GL, or where the surface
    // could not be made — and in BOTH cases the view is still a view: drawRect paints it.
    // Idempotent, so a caller that is not sure whether it already ran can just call it.
    bool makeGL(void)
        {
        if (glCtx != (pointer)0)
            {
            return true;
            }
        if (gDriver.glKind() == (i32)UX_GL_NONE)
            {
            return false;
            }
        if (owner != (UXViewTree*)0)
            {
            // The backend keys its surface on the neutral view and is handed nothing else, so
            // the view has to be reachable FROM the tree before the tree is realized.  This is
            // the same registration a control makes when it sets an action; a plain view has
            // never needed one, which is why it is here and not in attachTo.
            owner.setPeerOf(index, (pointer)self);
            owner.realize(); // the surface is the backend's, made during realization
            }
        glCtx = gDriver.makeGLContext((pointer)self);
        return glCtx != (pointer)0;
        }

    // The frame is finished.  Once per turn, after it is drawn -- and after any 2D over this view
    // has been damaged, so both land in one present.
    void presentGL(void)
        {
        if (glCtx != (pointer)0)
            {
            gDriver.presentGL((pointer)self);
            }
        }

    // Release the context.  Idempotent, because a GL client that double-frees on window
    // close is the classic crash.
    void destroyGL(void)
        {
        if (glCtx == (pointer)0)
            {
            return;
            }
        gDriver.destroyGLContext((pointer)self);
        glCtx = (pointer)0;
        }

    // The context dies with the view — this is the contract the driver seam states, not a
    // tidiness rule: it is where GL clients leak and crash on window close.
    void removeFromSuperview(void)
        {
        self.destroyGL();
        super.removeFromSuperview();
        }
    void dealloc(void)
        {
        self.destroyGL();
        }
    }

// ---- drawing a subtree into a native sub-surface ------------------------------------------------
// A native sub-surface (an AppKit scroll view's document view, or a plain view that paints in its
// own surface) is a SECOND drawing surface at its own 0,0.  To fill it, the driver's tree walk is
// pointed at the node whose subtree is the picture and the draw offset is set to that node's
// absolute position, so every view in the subtree lands at surface-local coordinates.  Both the
// scroll document and the self-surface go through here; they differ only in which node they name.
i32 ux_surface_userdraw(pointer tree, i32 obj, pointer ud)
    {
    UXViewTree* vt = (UXViewTree*)ud;
    UXView* v = (UXView* ?)vt.viewAt((u16)obj);
    if (v == (UXView*)0)
        {
        return (i32)0;
        }
    UXRect abs = vt.absoluteFrame((u16)obj);
    UXGraphics* g = gDriver.beginViewDraw((i32)abs.x, (i32)abs.y, (i32)abs.w, (i32)abs.h);
    v.drawRect(g, UXGeom.make((i16)0, (i16)0, abs.w, abs.h));
    gDriver.endViewDraw();
    return (i32)0;
    }
// Draw `node`'s subtree into a surface `w`x`h` whose 0,0 is the node's top-left.
void ux_draw_node_surface(UXViewTree* vt, i32 node, i32 w, i32 h)
    {
    if (vt == (UXViewTree*)0 || node < (i32)0)
        {
        return;
        }
    UXRect abs = vt.absoluteFrame((u16)node);
    gDriver.setDrawOffset((i32)abs.x, (i32)abs.y);
    gDriver.treeSetUserDraw((pointer)&ux_surface_userdraw, (pointer)vt);
    gDriver.treeDraw((pointer)vt.objects(), node, (i32)0, (i32)0, w, h);
    gDriver.setDrawOffset((i32)0, (i32)0);
    }
// The shim's callback for a self-surface view: it is handed the VIEW, and draws that view's subtree.
void ux_view_surface_draw(UXView* v, i32 w, i32 h)
    {
    if (v == (UXView*)0)
        {
        return;
        }
    ux_draw_node_surface(v.owner, (i32)v.index, w, h);
    }
