// RKDrag.xc — direct manipulation: pick an object up and move or resize it.
//
// TWO PIECES, and the split is the point.  RKDrag is a state machine over the
// MODEL — press, step, release — with no view, no driver and no events in it,
// so every rule about what a drag does can be tested headlessly.  RKEditOverlay
// is the thin input surface that feeds it real pointer positions.
//
// WHY AN OVERLAY AT ALL.  The canvas hosts real UXKit widgets, which is what
// makes what the designer sees the thing that will run — but a real button
// wants to be pressed, and on a design surface a click must SELECT it instead.
// A transparent view covering the canvas, added last so it hit-tests first,
// takes every click before the widgets underneath ever see it.  The canvas
// stays live-looking and stops being live, which is exactly the trade an
// interface builder wants.
//
// COORDINATES.  Three spaces, and mixing them is the classic way to get a drag
// that lags or drifts:
//   window   — what a UXEvent carries
//   canvas   — the pane the form is realized into; the root's children sit here
//              at their own model x/y, so canvas == "absolute within the form"
//   parent   — an object's x/y are relative to its PARENT (GEM's rule)
// Dragging happens in PARENT space, because that is the space the model stores
// and the space snapping wants: siblings are parent-relative, and the parent's
// own rect is simply (0,0,w,h).
#import "Array.xc"
#import "UXView.xc"
#import "UXGraphics.xc"
#import "UXGeometry.xc"
#import "UXEvent.xc"
#import "UXViewDriver.xc"
#import "UXApplication.xc"
#import "RKModel.xc"
#import "RKGuides.xc"

#define RK_MODE_NONE 0
#define RK_MODE_MOVE 1
#define RK_MODE_SIZE 2

#define RK_GRAB 6 // how close to a corner counts as grabbing the handle

class RKDrag : Object
    {
    // The model being edited.  STRONG, deliberately.
    //
    // These were `weak:` on the reasoning that the document owns the model and
    // outlives any drag -- true, but weak buys nothing here and cost a crash:
    // there is no cycle to break, because an RKObject never references the
    // editor.  Weak is for breaking ownership loops, and reaching for it where
    // no loop exists is all risk and no benefit.
    //
    // The crash: writing a weak reference to a model object freed that object
    // while the document still held it, and a later walk of the tree hit
    // scribbled memory.  Narrowed to a single declaration -- making
    // RKEditOverlay.selection strong fixed it -- but NOT reducible to a
    // standalone case: a weak field is well-behaved in a plain class, a deep
    // subclass, alongside callbacks, and on a live view in a window tree
    // (probe_weak2/3/4).  Filed as a compiler bug; see
    // private:docs/bugs/036-weak-field-write-frees-assignee.md.  The gate that pins it
    // is rocks-lifetime.
    RKObject* root;
    RKObject* target;
    RKObject* parentObj;

    i32 mode;
    i32 parentAX, parentAY; // the parent's origin, in canvas coordinates
    i32 grabDX, grabDY;     // pointer offset inside the object at press
    i32 startX, startY, startW, startH;

    // Both default ON, per the editor's own preference; the menu flips them.
    bool snapOn;
    bool guidesOn;

    // The lines the CURRENT step snapped to, in CANVAS coordinates so the
    // overlay can draw them without knowing which parent they came from.
    Array<RKGuide>* guides;

    void init(void)
        {
        root = (RKObject*)0;
        target = (RKObject*)0;
        parentObj = (RKObject*)0;
        mode = (i32)RK_MODE_NONE;
        parentAX = (i32)0;
        parentAY = (i32)0;
        grabDX = (i32)0;
        grabDY = (i32)0;
        startX = (i32)0;
        startY = (i32)0;
        startW = (i32)0;
        startH = (i32)0;
        snapOn = true;
        guidesOn = true;
        guides = new Array();
        }

    // ---- pure geometry over the model --------------------------------------

    // The object whose children include `o`, or 0 if `o` is the root or absent.
    // A linear search rather than a parent pointer in RKObject: the model is
    // also what gets WRITTEN back to a .rsc, and a back-pointer is one more
    // thing the reader, the writer and every edit must keep consistent.  Forms
    // are tens of objects, so the search costs nothing a drag can feel.
    static RKObject* parentOf(RKObject* root, RKObject* o)
        {
        if (root == (RKObject*)0 || o == (RKObject*)0)
            {
            return (RKObject*)0;
            }
        for (i32 i = (i32)0; i < root.childCount(); i = i + (i32)1)
            {
            RKObject* c = root.childAt(i);
            if (c == o)
                {
                return root;
                }
            RKObject* deep = RKDrag.parentOf(c, o);
            if (deep != (RKObject*)0)
                {
                return deep;
                }
            }
        return (RKObject*)0;
        }

    // `o`'s origin in CANVAS coordinates: every ancestor's x/y summed, and the
    // ROOT's own x/y deliberately excluded — RKCanvas realizes the root's
    // children straight into the pane, so the root is the canvas, not a box
    // inside it.  Returns false if `o` is not in this tree at all.
    static bool absOrigin(RKObject* root, RKObject* o, i32* ax, i32* ay)
        {
        ax[0] = (i32)0;
        ay[0] = (i32)0;
        if (o == root)
            {
            return true;
            }
        RKObject* p = RKDrag.parentOf(root, o);
        if (p == (RKObject*)0)
            {
            return false;
            }
        i32 px = (i32)0;
        i32 py = (i32)0;
        if (!RKDrag.absOrigin(root, p, &px, &py))
            {
            return false;
            }
        ax[0] = px + o.x;
        ay[0] = py + o.y;
        return true;
        }

    // The object under a canvas point: DEEPEST first, so clicking a control
    // inside a group box picks the control and not the box.  The root is never
    // returned — clicking bare form background means "nothing", which is what
    // makes clicking away a deselect rather than a selection of the form.
    static RKObject* hitTest(RKObject* root, i32 px, i32 py)
        {
        if (root == (RKObject*)0)
            {
            return (RKObject*)0;
            }
        return RKDrag.deepestAt(root, (i32)0, (i32)0, px, py);
        }
    static RKObject* deepestAt(RKObject* o, i32 ox, i32 oy, i32 px, i32 py)
        {
        RKObject* best = (RKObject*)0;
        for (i32 i = (i32)0; i < o.childCount(); i = i + (i32)1)
            {
            RKObject* c = o.childAt(i);
            // A hidden subtree is not on screen, so it cannot be clicked —
            // otherwise an invisible object would silently steal the press.
            if ((c.flags & (i32)RKF_HIDETREE) != (i32)0)
                {
                continue;
                }
            i32 cx = ox + c.x;
            i32 cy = oy + c.y;
            if (px >= cx && px < cx + c.w && py >= cy && py < cy + c.h)
                {
                best = c;
                }
            RKObject* deeper = RKDrag.deepestAt(c, cx, cy, px, py);
            if (deeper != (RKObject*)0)
                {
                best = deeper;
                }
            }
        return best;
        }

    // Which corner handle a point grabs (0=TL 1=TR 2=BL 3=BR), or -1 for none.
    // `r` is in canvas coordinates.  The hot zone extends OUTSIDE the rect as
    // well as in, so a small object stays resizable instead of being all
    // handles and no middle.
    static i32 handleAt(UXRect r, i32 px, i32 py)
        {
        i32 x0 = (i32)r.x;
        i32 y0 = (i32)r.y;
        i32 x1 = x0 + (i32)r.w;
        i32 y1 = y0 + (i32)r.h;
        bool L = px >= x0 - (i32)RK_GRAB && px <= x0 + (i32)RK_GRAB;
        bool R = px >= x1 - (i32)RK_GRAB && px <= x1 + (i32)RK_GRAB;
        bool T = py >= y0 - (i32)RK_GRAB && py <= y0 + (i32)RK_GRAB;
        bool B = py >= y1 - (i32)RK_GRAB && py <= y1 + (i32)RK_GRAB;
        if (L && T)
            {
            return (i32)0;
            }
        if (R && T)
            {
            return (i32)1;
            }
        if (L && B)
            {
            return (i32)2;
            }
        if (R && B)
            {
            return (i32)3;
            }
        return (i32)-1;
        }

    // The object's rect in canvas coordinates.
    UXRect canvasRect(RKObject* o)
        {
        i32 ax = (i32)0;
        i32 ay = (i32)0;
        if (!RKDrag.absOrigin(root, o, &ax, &ay))
            {
            return UXGeom.zero();
            }
        return UXGeom.make((i16)ax, (i16)ay, (i16)o.w, (i16)o.h);
        }

    // ---- the state machine ---------------------------------------------------

    // Press at a canvas point.  `sel` is what is currently selected, and it is
    // consulted FIRST: a press near its corner is a resize even when the point
    // is over some other object, because the handles are drawn on top and the
    // designer is aiming at what they can see.
    //
    // Returns the object now being dragged, or 0 for a press on bare
    // background — which the caller should treat as a deselect.
    RKObject* begin(RKObject* r, RKObject* sel, i32 px, i32 py)
        {
        root = r;
        guides.removeAll();
        mode = (i32)RK_MODE_NONE;
        target = (RKObject*)0;
        if (r == (RKObject*)0)
            {
            return (RKObject*)0;
            }

        i32 wantMode = (i32)RK_MODE_MOVE;
        RKObject* o = (RKObject*)0;
        if (sel != (RKObject*)0 && RKDrag.handleAt(self.canvasRect(sel), px, py) >= (i32)0)
            {
            o = sel;
            wantMode = (i32)RK_MODE_SIZE;
            }
        else
            {
            o = RKDrag.hitTest(r, px, py);
            }
        if (o == (RKObject*)0)
            {
            return (RKObject*)0;
            }

        parentObj = RKDrag.parentOf(r, o);
        if (parentObj == (RKObject*)0)
            {
            return (RKObject*)0;
            }
        i32 ax = (i32)0;
        i32 ay = (i32)0;
        if (!RKDrag.absOrigin(r, parentObj, &ax, &ay))
            {
            return (RKObject*)0;
            }

        target = o;
        mode = wantMode;
        parentAX = ax;
        parentAY = ay;
        startX = o.x;
        startY = o.y;
        startW = o.w;
        startH = o.h;
        // The offset from the press to the object's origin, so the object
        // moves WITH the pointer instead of jumping its corner under it.
        grabDX = (px - ax) - o.x;
        grabDY = (py - ay) - o.y;
        return o;
        }

    // One step of the drag: the pointer is now at this canvas point.  Rewrites
    // the target's rect and republishes the guides.
    //
    // Every step recomputes from the PRESS position rather than accumulating
    // deltas.  Accumulation and snapping fight each other — a snapped step
    // would feed its own correction into the next one, so the object creeps
    // away from the pointer for as long as the drag lasts.
    void step(i32 px, i32 py)
        {
        if (mode == (i32)RK_MODE_NONE || target == (RKObject*)0)
            {
            return;
            }
        guides.removeAll();

        UXRect parentRect = UXGeom.make((i16)0, (i16)0, (i16)parentObj.w, (i16)parentObj.h);
        Array<RKRectBox>* sibs = new Array();
        for (i32 i = (i32)0; i < parentObj.childCount(); i = i + (i32)1)
            {
            RKObject* c = parentObj.childAt(i);
            // never align a thing to itself
            if (c == target)
                {
                continue;
                }
            sibs.add(RKRectBox.of(UXGeom.make((i16)c.x, (i16)c.y, (i16)c.w, (i16)c.h)));
            }

        i32 lx = px - parentAX;
        i32 ly = py - parentAY; // pointer, parent-relative
        Array<RKGuide>* local = new Array();
        UXRect out;
        if (mode == (i32)RK_MODE_MOVE)
            {
            UXRect want = UXGeom.make((i16)(lx - grabDX), (i16)(ly - grabDY),
                                      (i16)startW, (i16)startH);
            out = RKGuides.snapMove(want, sibs, parentRect, snapOn, local);
            }
        else
            {
            i32 nw = lx - startX;
            if (nw < (i32)4)
                {
                nw = (i32)4;
                }
            i32 nh = ly - startY;
            if (nh < (i32)4)
                {
                nh = (i32)4;
                }
            UXRect want = UXGeom.make((i16)startX, (i16)startY, (i16)nw, (i16)nh);
            out = RKGuides.snapResize(want, sibs, parentRect, snapOn, local);
            }
        target.x = (i32)out.x;
        target.y = (i32)out.y;
        target.w = (i32)out.w;
        target.h = (i32)out.h;

        // Guides come back parent-relative; the overlay draws in canvas space.
        if (guidesOn)
            {
            for (i32 i = (i32)0; i < (i32)local.count(); i = i + (i32)1)
                {
                RKGuide* g = (RKGuide* ?)local.get((u16)i);
                guides.add(RKGuide.make(g.pos + (g.vertical ? parentAX : parentAY), g.vertical));
                }
            }
        }

    void end(void)
        {
        mode = (i32)RK_MODE_NONE;
        guides.removeAll();
        }

    bool isDragging(void)
        {
        return mode != (i32)RK_MODE_NONE;
        }
    bool didMove(void)
        {
        if (target == (RKObject*)0)
            {
            return false;
            }
        return target.x != startX || target.y != startY || target.w != startW || target.h != startH;
        }

    // Put the object back where it was.  A drag that is abandoned must leave
    // the model exactly as it found it, or an editor quietly accumulates
    // one-pixel edits nobody asked for.
    void cancel(void)
        {
        if (target != (RKObject*)0)
            {
            target.x = startX;
            target.y = startY;
            target.w = startW;
            target.h = startH;
            }
        self.end();
        }
    }

    // The transparent input surface over the canvas.
    //
    // It owns no model knowledge: it turns window coordinates into canvas ones and
    // hands them to RKDrag, then tells its client what happened.  That keeps the
    // controller (which knows about documents, selection and the inspector) out of
    // the event loop, and keeps this out of the model.
    class RKEditOverlay : UXShieldView
    {
    RKDrag* drag;
    // Set by the controller before each press; the overlay itself has no
    // opinion about what is selected.  STRONG -- see the note on RKDrag.root:
    // this exact field, declared weak, was what freed the model.
    RKObject* selection;

    // What the editor is told.  Callbacks rather than a controller pointer, so
    // the overlay can be driven by a test with no controller at all.
    callback picked void(RKObject* o);  // press landed on this (0 = background)
    callback changed void(RKObject* o); // the model's rect moved this step
    callback ended void(RKObject* o);   // the drag finished

    void init(void)
        {
        super.init();
        drag = new RKDrag();
        selection = (RKObject*)0;
        picked = (callback void(RKObject * o))0;
        changed = (callback void(RKObject * o))0;
        ended = (callback void(RKObject * o))0;
        }

    // Only the guides.  Anything else drawn here would sit on top of the whole
    // form, and the selection frame is a separate view precisely so it can be
    // moved without repainting this one.
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        if (!drag.guidesOn)
            {
            return;
            }
        UXRect b = self.bounds();
        for (i32 i = (i32)0; i < (i32)drag.guides.count(); i = i + (i32)1)
            {
            RKGuide* gd = (RKGuide* ?)drag.guides.get((u16)i);
            if (gd.vertical)
                {
                g.fillRect(UXGeom.make((i16)gd.pos, (i16)0, (i16)1, b.h), (i32)1);
                }
            else
                {
                g.fillRect(UXGeom.make((i16)0, (i16)gd.pos, b.w, (i16)1), (i32)1);
                }
            }
        }

    // A press: select, then track the pointer until the button comes up.
    //
    // The loop is MODAL (trackDragStep parks the run loop), which is how every
    // other toolkit-drawn drag in UXKit works — a slider, a split divider.  The
    // alternative, a mouseDragged event stream, does not exist on the backends
    // whose native controls own the pointer once it is down.
    void mouseDown(UXEvent* e)
        {
        i32 cx = (i32)0;
        i32 cy = (i32)0;
        self.toCanvas((i32)e.x, (i32)e.y, &cx, &cy);
        RKObject* o = drag.begin(drag.root, self.currentSelection(), cx, cy);
        if (picked)
            {
            picked(o);
            }
        if (o == (RKObject*)0)
            {
            return;
            }

        i32 x = (i32)e.x;
        i32 y = (i32)e.y;
        while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
            self.toCanvas(x, y, &cx, &cy);
            drag.step(cx, cy);
            if (changed)
                {
                changed(o);
                }
            self.setNeedsDisplay();
            if (gApp != (UXApplication*)0)
                {
                gApp.displayIfNeeded();
                }
            }
        drag.end();
        self.setNeedsDisplay();
        if (ended)
            {
            ended(o);
            }
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }

    // Window coordinates to canvas ones.  The overlay covers the canvas, so its
    // own absolute frame IS the canvas origin — no need to ask the canvas.
    void toCanvas(i32 wx, i32 wy, i32* cx, i32* cy)
        {
        UXRect a = self.absoluteFrame();
        cx[0] = wx - (i32)a.x;
        cy[0] = wy - (i32)a.y;
        }

    RKObject* currentSelection(void)
        {
        return selection;
        }
    void setSelection(RKObject* o)
        {
        selection = o;
        }
    void setRoot(RKObject* r)
        {
        drag.root = r;
        }
    }
