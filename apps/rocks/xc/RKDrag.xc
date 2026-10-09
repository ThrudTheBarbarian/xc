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
#import "UXRscModel.xc"
#import "RKGuides.xc"

#define RK_MODE_NONE 0
#define RK_MODE_MOVE 1
#define RK_MODE_SIZE 2

#define RK_GRAB 8 // how close to a corner counts as grabbing the handle (the handle is 7px)
#define RK_FORM_HANDLE 8 // a form grab handle, in pixels
#define RK_FORM_OFF 4    // how far outside the form's edge the form handles sit
#define RK_MOVE_HANDLE_W 40 // the form's move grip, above the panel's centre
#define RK_MOVE_HANDLE_H 8
#define RK_MOVE_HANDLE_GAP 6

class RKDrag : Object
    {
    // The model being edited.  STRONG, deliberately.
    //
    // These were `weak:` on the reasoning that the document owns the model and
    // outlives any drag -- true, but weak buys nothing here and cost a crash:
    // there is no cycle to break, because an UXRscObject never references the
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
    UXRscObject* root;
    UXRscObject* target;
    UXRscObject* parentObj;

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
        root = (UXRscObject*)0;
        target = (UXRscObject*)0;
        parentObj = (UXRscObject*)0;
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
    // A linear search rather than a parent pointer in UXRscObject: the model is
    // also what gets WRITTEN back to a .rsc, and a back-pointer is one more
    // thing the reader, the writer and every edit must keep consistent.  Forms
    // are tens of objects, so the search costs nothing a drag can feel.
    static UXRscObject* parentOf(UXRscObject* root, UXRscObject* o)
        {
        if (root == (UXRscObject*)0 || o == (UXRscObject*)0)
            {
            return (UXRscObject*)0;
            }
        for (i32 i = (i32)0; i < root.childCount(); i = i + (i32)1)
            {
            UXRscObject* c = root.childAt(i);
            if (c == o)
                {
                return root;
                }
            UXRscObject* deep = RKDrag.parentOf(c, o);
            if (deep != (UXRscObject*)0)
                {
                return deep;
                }
            }
        return (UXRscObject*)0;
        }

    // `o`'s origin in CANVAS coordinates: every ancestor's x/y summed, and the
    // ROOT's own x/y deliberately excluded — RKCanvas realizes the root's
    // children straight into the pane, so the root is the canvas, not a box
    // inside it.  Returns false if `o` is not in this tree at all.
    static bool absOrigin(UXRscObject* root, UXRscObject* o, i32* ax, i32* ay)
        {
        ax[0] = (i32)0;
        ay[0] = (i32)0;
        if (o == root)
            {
            return true;
            }
        UXRscObject* p = RKDrag.parentOf(root, o);
        if (p == (UXRscObject*)0)
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
    static UXRscObject* hitTest(UXRscObject* root, i32 px, i32 py)
        {
        if (root == (UXRscObject*)0)
            {
            return (UXRscObject*)0;
            }
        return RKDrag.deepestAt(root, (i32)0, (i32)0, px, py);
        }
    static UXRscObject* deepestAt(UXRscObject* o, i32 ox, i32 oy, i32 px, i32 py)
        {
        UXRscObject* best = (UXRscObject*)0;
        for (i32 i = (i32)0; i < o.childCount(); i = i + (i32)1)
            {
            UXRscObject* c = o.childAt(i);
            // A hidden subtree is not on screen, so it cannot be clicked —
            // otherwise an invisible object would silently steal the press.
            if ((c.flags & (i32)UXR_F_HIDETREE) != (i32)0)
                {
                continue;
                }
            i32 cx = ox + c.x;
            i32 cy = oy + c.y;
            if (px >= cx && px < cx + c.w && py >= cy && py < cy + c.h)
                {
                best = c;
                }
            UXRscObject* deeper = RKDrag.deepestAt(c, cx, cy, px, py);
            if (deeper != (UXRscObject*)0)
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
    UXRect canvasRect(UXRscObject* o)
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
    UXRscObject* begin(UXRscObject* r, UXRscObject* sel, i32 px, i32 py)
        {
        root = r;
        guides.removeAll();
        mode = (i32)RK_MODE_NONE;
        target = (UXRscObject*)0;
        if (r == (UXRscObject*)0)
            {
            return (UXRscObject*)0;
            }

        i32 wantMode = (i32)RK_MODE_MOVE;
        UXRscObject* o = (UXRscObject*)0;
        if (sel != (UXRscObject*)0 && RKDrag.handleAt(self.canvasRect(sel), px, py) >= (i32)0)
            {
            o = sel;
            wantMode = (i32)RK_MODE_SIZE;
            }
        else
            {
            o = RKDrag.hitTest(r, px, py);
            }
        if (o == (UXRscObject*)0)
            {
            return (UXRscObject*)0;
            }

        parentObj = RKDrag.parentOf(r, o);
        if (parentObj == (UXRscObject*)0)
            {
            return (UXRscObject*)0;
            }
        i32 ax = (i32)0;
        i32 ay = (i32)0;
        if (!RKDrag.absOrigin(r, parentObj, &ax, &ay))
            {
            return (UXRscObject*)0;
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
        if (mode == (i32)RK_MODE_NONE || target == (UXRscObject*)0)
            {
            return;
            }
        guides.removeAll();

        UXRect parentRect = UXGeom.make((i16)0, (i16)0, (i16)parentObj.w, (i16)parentObj.h);
        Array<RKRectBox>* sibs = new Array();
        for (i32 i = (i32)0; i < parentObj.childCount(); i = i + (i32)1)
            {
            UXRscObject* c = parentObj.childAt(i);
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
        if (target == (UXRscObject*)0)
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
        if (target != (UXRscObject*)0)
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
    UXRscObject* selection;

    // What the editor is told.  Callbacks rather than a controller pointer, so
    // the overlay can be driven by a test with no controller at all.
    callback picked void(UXRscObject* o);  // press landed on this (0 = background)
    callback changed void(UXRscObject* o); // the model's rect moved this step
    callback ended void(UXRscObject* o);   // the drag finished
    // Asked first, with the press point on the canvas: true takes the press (the editor is placing
    // an object from the library), and nothing is selected or dragged.
    callback placeAt bool(i32 cx, i32 cy);
    callback deleteKey void(void); // Delete or Backspace while the canvas has the keyboard
    // A control-drag (the secondary button) starting on a control: the editor draws a connection.
    callback wireFrom void(UXRscObject* o, i32 wx, i32 wy);
    // A pointer move over the canvas, in form coordinates: the Size tab's preview runs while the
    // mouse is over the selected control.
    callback hovered void(i32 cx, i32 cy);
    // The line being drawn, in canvas coordinates, while `wiring`; and the rect of the control the
    // pointer is over, highlighted as the drop target (w = 0: none).
    bool wiring;
    // Where the form sits on the canvas (RKBackdrop's panel): the drag works in the form's
    // coordinates, the overlay covers the whole canvas.  And the last press, in form coordinates.
    i32 offX;
    i32 offY;
    i32 pressX;
    i32 pressY;
    i32 lineX0;
    i32 lineY0;
    i32 lineX1;
    i32 lineY1;
    UXRect hot;

    // The form itself, for the four grab handles OUTSIDE its panel.  The controller sets the size on
    // every show; a press on a handle resizes the form through formResized (the form is the tree
    // ROOT, which RKDrag will not touch, so this is its own little drag).
    i32 formW;
    i32 formH;
    callback formResized void(i32 w, i32 h, bool done);
    bool resizing;
    i32 rCorner;
    i32 rPressX;
    i32 rPressY;
    i32 rStartW;
    i32 rStartH;
    i32 rNewW;
    i32 rNewH;

    // Moving the form on the grid: a press on the move grip above the panel, or on the panel's bare
    // background, carries the whole form, changing where RKBackdrop draws the panel and where the pane
    // sits.  formMoved reports the new offset; `done` marks the release (a place to snapshot undo).
    callback formMoved void(i32 offX, i32 offY, bool done);
    bool movingForm;
    i32 mfRefX;  // the press, in raw canvas coordinates (offX/offY excluded, since they move)
    i32 mfRefY;
    i32 mfOffX;  // the offset when the move began
    i32 mfOffY;

    void init(void)
        {
        super.init();
        placeAt = (callback bool(i32 cx, i32 cy))0;
        deleteKey = (callback void(void))0;
        wireFrom = (callback void(UXRscObject * o, i32 wx, i32 wy))0;
        hovered = (callback void(i32 cx, i32 cy))0;
        wiring = false;
        offX = (i32)0;
        offY = (i32)0;
        pressX = (i32)-1;
        pressY = (i32)-1;
        hot = UXGeom.make((i16)0, (i16)0, (i16)0, (i16)0);
        formW = (i32)0;
        formH = (i32)0;
        formResized = (callback void(i32 w, i32 h, bool done))0;
        resizing = false;
        rCorner = (i32)-1;
        rPressX = (i32)0;
        rPressY = (i32)0;
        rStartW = (i32)0;
        rStartH = (i32)0;
        rNewW = (i32)0;
        rNewH = (i32)0;
        formMoved = (callback void(i32 offX, i32 offY, bool done))0;
        movingForm = false;
        mfRefX = (i32)0;
        mfRefY = (i32)0;
        mfOffX = (i32)0;
        mfOffY = (i32)0;
        drag = new RKDrag();
        selection = (UXRscObject*)0;
        tracking = (UXRscObject*)0;
        picked = (callback void(UXRscObject * o))0;
        changed = (callback void(UXRscObject * o))0;
        ended = (callback void(UXRscObject * o))0;
        }

    // Only the guides.  Anything else drawn here would sit on top of the whole
    // form, and the selection frame is a separate view precisely so it can be
    // moved without repainting this one.
    void drawRect(UXGraphics* g, UXRect dirty)
        {
        // The form's four grab handles, OUTSIDE its panel, drawn whatever else is going on: a view
        // that covers the form cannot hide them, and a press on one cannot reach a widget underneath.
        if (formW > (i32)0 && formH > (i32)0)
            {
            for (i32 c = (i32)0; c < (i32)4; c = c + (i32)1)
                {
                i32 bx = (i32)0;
                i32 by = (i32)0;
                RKEditOverlay.formHandle(c, offX, offY, formW, formH, &bx, &by);
                RKEditOverlay.handle(g, (i16)bx, (i16)by);
                }
            // The move grip: a bar above the panel's centre.  Dragging it (or the panel's background)
            // carries the form on the grid, so moving it is discoverable rather than a hidden mode.
            i32 gx = (i32)0;
            i32 gy = (i32)0;
            RKEditOverlay.moveHandle(offX, offY, formW, &gx, &gy);
            g.fillRectRGB(UXGeom.make((i16)gx, (i16)gy, (i16)RK_MOVE_HANDLE_W, (i16)RK_MOVE_HANDLE_H), (i32)255, (i32)255, (i32)255);
            g.fillRectRGB(UXGeom.make((i16)gx, (i16)gy, (i16)RK_MOVE_HANDLE_W, (i16)1), (i32)110, (i32)120, (i32)140);
            g.fillRectRGB(UXGeom.make((i16)gx, (i16)((i32)gy + (i32)RK_MOVE_HANDLE_H - (i32)1), (i16)RK_MOVE_HANDLE_W, (i16)1), (i32)110, (i32)120, (i32)140);
            for (i32 d = (i32)0; d < (i32)3; d = d + (i32)1)
                {
                i32 dx = (i32)gx + (i32)12 + d * (i32)8;
                g.fillRectRGB(UXGeom.make((i16)dx, (i16)((i32)gy + (i32)2), (i16)2, (i16)4), (i32)110, (i32)120, (i32)140);
                }
            }
        if (wiring)
            {
            if (hot.w > (i16)0)
                {
                RKEditOverlay.outline(g, hot);
                }
            RKEditOverlay.line(g, lineX0, lineY0, lineX1, lineY1);
            return;
            }
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
                g.fillRect(UXGeom.make((i16)(gd.pos + offX), (i16)0, (i16)1, b.h), (i32)1);
                }
            else
                {
                g.fillRect(UXGeom.make((i16)0, (i16)(gd.pos + offY), b.w, (i16)1), (i32)1);
                }
            }
        }

    // A press: select, then track the pointer until the button comes up.
    //
    // With a mouse the loop is MODAL (trackDragStep parks the run loop), which is how every other
    // toolkit-drawn drag in UXKit works -- a slider, a split divider.  On a touch backend the
    // platform owns the loop and the drag arrives as events instead (dragTrackingIsModal() is
    // false): the press only begins the drag here, and mouseDragged / mouseUp carry it on.  The
    // drag itself -- step, end, the callbacks -- is the same code either way.
    UXRscObject* tracking; // the object a touch drag is moving, between its events
    void mouseDown(UXEvent* e)
        {
        i32 cx = (i32)0;
        i32 cy = (i32)0;
        self.toCanvas((i32)e.x, (i32)e.y, &cx, &cy);
        pressX = cx;
        pressY = cy;
        // A press on a form handle resizes the form, before anything else, since the handles sit
        // outside the panel and above everything.
        i32 hc = self.formHandleAt(cx, cy);
        if (hc >= (i32)0)
            {
            self.resizeForm(hc, e);
            return;
            }
        if (placeAt && placeAt(cx, cy))
            {
            return;
            }
        // The move grip sits above the panel, over no control: pressing it carries the form.  It comes
        // before the selection, so a grip press does not deselect what the designer had selected.
        if (self.gripAt(cx, cy))
            {
            self.formMoveBegin((i32)e.x, (i32)e.y, e);
            return;
            }
        UXRscObject* o = drag.begin(drag.root, self.currentSelection(), cx, cy);
        if (picked)
            {
            picked(o);
            }
        if (o == (UXRscObject*)0)
            {
            // A press on the panel's bare background (which just selected the form) carries the form
            // too, so grabbing the form anywhere but a control moves it on the grid.
            if (self.onPanelBg(cx, cy))
                {
                self.formMoveBegin((i32)e.x, (i32)e.y, e);
                }
            return;
            }
        if (!gDriver.dragTrackingIsModal())
            {
            tracking = o; // mouseDragged and mouseUp take it from here
            return;
            }
        i32 x = (i32)e.x;
        i32 y = (i32)e.y;
        while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
            self.stepTo(o, x, y);
            }
        self.finish(o);
        }
    // A click on the canvas gives it the keyboard, so Delete and Backspace delete what is selected;
    // a text field keeps them while it is being typed in.
    bool acceptsFirstResponder(void)
        {
        return true;
        }
    void keyDown(UXEvent* e)
        {
        u16 ch = e.key & (u16)UX_KEY_ASCII;
        bool del = e.key == (u16)$F728 || (e.key < (u16)$100 && (ch == (u16)$7F || ch == (u16)$08));
        if (del && deleteKey)
            {
            deleteKey();
            return;
            }
        super.keyDown(e);
        }
    void mouseMoved(UXEvent* e)
        {
        if (hovered)
            {
            i32 cx = (i32)0;
            i32 cy = (i32)0;
            self.toCanvas((i32)e.x, (i32)e.y, &cx, &cy);
            hovered(cx, cy);
            }
        }
    // The secondary button (on a Mac, a control-click) on a control starts a connection from it;
    // let go where it was pressed, it opens the control's menu.
    void rightMouseDown(UXEvent* e)
        {
        i32 cx = (i32)0;
        i32 cy = (i32)0;
        self.toCanvas((i32)e.x, (i32)e.y, &cx, &cy);
        UXRscObject* o = RKDrag.hitTest(drag.root, cx, cy);
        if (o != (UXRscObject*)0 && wireFrom)
            {
            wireFrom(o, (i32)e.x, (i32)e.y);
            }
        }
    // Show the line from (x0, y0) to (x1, y1), canvas coordinates, with `target` highlighted.
    void showLine(i32 x0, i32 y0, i32 x1, i32 y1, UXRect target)
        {
        wiring = true;
        lineX0 = x0;
        lineY0 = y0;
        lineX1 = x1;
        lineY1 = y1;
        hot = target;
        self.setNeedsDisplay();
        }
    void hideLine(void)
        {
        wiring = false;
        hot = UXGeom.make((i16)0, (i16)0, (i16)0, (i16)0);
        self.setNeedsDisplay();
        }
    // Interface Builder's blue, two points wide: a run of small squares, as the graphics seam has
    // no line of its own.
    static void line(UXGraphics* g, i32 x0, i32 y0, i32 x1, i32 y1)
        {
        i32 dx = x1 - x0;
        i32 dy = y1 - y0;
        i32 ax = dx < (i32)0 ? (i32)0 - dx : dx;
        i32 ay = dy < (i32)0 ? (i32)0 - dy : dy;
        i32 n = ax > ay ? ax : ay;
        if (n == (i32)0)
            {
            n = (i32)1;
            }
        for (i32 i = (i32)0; i <= n; i = i + (i32)2)
            {
            i32 x = x0 + dx * i / n;
            i32 y = y0 + dy * i / n;
            g.fillRectRGB(UXGeom.make((i16)(x - (i32)1), (i16)(y - (i32)1), (i16)3, (i16)3), (i32)30, (i32)120, (i32)255);
            }
        }
    static void outline(UXGraphics* g, UXRect r)
        {
        g.fillRectRGB(UXGeom.make(r.x, r.y, r.w, (i16)2), (i32)30, (i32)120, (i32)255);
        g.fillRectRGB(UXGeom.make(r.x, (i16)((i32)r.y + (i32)r.h - (i32)2), r.w, (i16)2), (i32)30, (i32)120, (i32)255);
        g.fillRectRGB(UXGeom.make(r.x, r.y, (i16)2, r.h), (i32)30, (i32)120, (i32)255);
        g.fillRectRGB(UXGeom.make((i16)((i32)r.x + (i32)r.w - (i32)2), r.y, (i16)2, r.h), (i32)30, (i32)120, (i32)255);
        }

    void mouseDragged(UXEvent* e)
        {
        if (resizing)
            {
            self.formStep((i32)e.x, (i32)e.y);
            return;
            }
        if (movingForm)
            {
            self.formMoveStep((i32)e.x, (i32)e.y);
            return;
            }
        if (tracking != (UXRscObject*)0)
            {
            self.stepTo(tracking, (i32)e.x, (i32)e.y);
            }
        }
    void mouseUp(UXEvent* e)
        {
        if (movingForm)
            {
            self.formMoveStep((i32)e.x, (i32)e.y);
            self.formMoveEnd();
            return;
            }
        if (resizing)
            {
            self.formStep((i32)e.x, (i32)e.y);
            self.formEnd();
            return;
            }
        UXRscObject* o = tracking;
        tracking = (UXRscObject*)0;
        if (o != (UXRscObject*)0)
            {
            self.finish(o);
            }
        }
    // One step of a drag, at a window point.
    void stepTo(UXRscObject* o, i32 x, i32 y)
        {
        i32 cx = (i32)0;
        i32 cy = (i32)0;
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
    void finish(UXRscObject* o)
        {
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

    // Window coordinates to the form's.  The overlay covers the canvas, so its own absolute frame
    // IS the canvas origin; the form sits at (offX, offY) on it.
    void toCanvas(i32 wx, i32 wy, i32* cx, i32* cy)
        {
        UXRect a = self.absoluteFrame();
        cx[0] = wx - (i32)a.x - offX;
        cy[0] = wy - (i32)a.y - offY;
        }
    // A rect in the form's coordinates, on the canvas.
    UXRect onCanvas(UXRect r)
        {
        return UXGeom.make((i16)((i32)r.x + offX), (i16)((i32)r.y + offY), r.w, r.h);
        }

    // The box of form handle c (0 TL, 1 TR, 2 BL, 3 BR) on the CANVAS, OUTSIDE the panel.  The panel
    // is at (ox, oy) size (fw, fh); the handle sits offset outside its corner.
    static void formHandle(i32 c, i32 ox, i32 oy, i32 fw, i32 fh, i32* bx, i32* by)
        {
        i32 s = (i32)RK_FORM_HANDLE;
        i32 off = (i32)RK_FORM_OFF;
        bx[0] = ox + ((c == (i32)1 || c == (i32)3) ? fw + off : (i32)0 - off - s);
        by[0] = oy + ((c == (i32)2 || c == (i32)3) ? fh + off : (i32)0 - off - s);
        }
    // The move grip's box on the CANVAS: centred above the panel's top edge, in the gap the panel's
    // label leaves.  (fw is the panel's width; the grip is centred on it.)
    static void moveHandle(i32 ox, i32 oy, i32 fw, i32* bx, i32* by)
        {
        bx[0] = ox + (fw - (i32)RK_MOVE_HANDLE_W) / (i32)2;
        by[0] = oy - (i32)RK_MOVE_HANDLE_H - (i32)RK_MOVE_HANDLE_GAP;
        }
    // Is a FORM-RELATIVE point on the move grip?  (The grip is above the panel, so fy < 0.)
    bool gripAt(i32 fx, i32 fy)
        {
        if (formW <= (i32)0 || formH <= (i32)0)
            {
            return false;
            }
        i32 gx = (formW - (i32)RK_MOVE_HANDLE_W) / (i32)2;
        i32 gy = (i32)0 - (i32)RK_MOVE_HANDLE_H - (i32)RK_MOVE_HANDLE_GAP;
        return fx >= gx && fx < gx + (i32)RK_MOVE_HANDLE_W && fy >= gy && fy < gy + (i32)RK_MOVE_HANDLE_H;
        }
    // Is a FORM-RELATIVE point on the panel itself (the form's background)?
    bool onPanelBg(i32 fx, i32 fy)
        {
        return formW > (i32)0 && formH > (i32)0 && fx >= (i32)0 && fy >= (i32)0 && fx < formW && fy < formH;
        }
    // Which form handle a FORM-RELATIVE point grabs, or -1.
    i32 formHandleAt(i32 fx, i32 fy)
        {
        if (formW <= (i32)0 || formH <= (i32)0)
            {
            return (i32)-1;
            }
        i32 s = (i32)RK_FORM_HANDLE;
        i32 off = (i32)RK_FORM_OFF;
        for (i32 c = (i32)0; c < (i32)4; c = c + (i32)1)
            {
            i32 hx = (c == (i32)1 || c == (i32)3) ? formW + off : (i32)0 - off - s;
            i32 hy = (c == (i32)2 || c == (i32)3) ? formH + off : (i32)0 - off - s;
            if (fx >= hx && fx < hx + s && fy >= hy && fy < hy + s)
                {
                return c;
                }
            }
        return (i32)-1;
        }
    // A white square with a dark border, as the selection frame's handles are.
    static void handle(UXGraphics* g, i16 x, i16 y)
        {
        i16 s = (i16)RK_FORM_HANDLE;
        g.fillRectRGB(UXGeom.make(x, y, s, s), (i32)255, (i32)255, (i32)255);
        g.fillRectRGB(UXGeom.make(x, y, s, (i16)1), (i32)38, (i32)38, (i32)38);
        g.fillRectRGB(UXGeom.make(x, (i16)((i32)y + (i32)s - (i32)1), s, (i16)1), (i32)38, (i32)38, (i32)38);
        g.fillRectRGB(UXGeom.make(x, y, (i16)1, s), (i32)38, (i32)38, (i32)38);
        g.fillRectRGB(UXGeom.make((i16)((i32)x + (i32)s - (i32)1), y, (i16)1, s), (i32)38, (i32)38, (i32)38);
        }
    void setForm(i32 w, i32 h)
        {
        formW = w;
        formH = h;
        self.setNeedsDisplay();
        }
    void setFormResized(callback f void(i32 w, i32 h, bool done))
        {
        formResized = f;
        }
    // A press on a form handle: resize the form, modally where the toolkit owns the loop.
    void resizeForm(i32 corner, UXEvent* e)
        {
        rCorner = corner;
        self.toCanvas((i32)e.x, (i32)e.y, &rPressX, &rPressY);
        rStartW = formW;
        rStartH = formH;
        rNewW = formW;
        rNewH = formH;
        resizing = true;
        if (!gDriver.dragTrackingIsModal())
            {
            return; // mouseDragged / mouseUp carry it
            }
        i32 x = (i32)e.x;
        i32 y = (i32)e.y;
        while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
            self.formStep(x, y);
            }
        self.formEnd();
        }
    void formStep(i32 wx, i32 wy)
        {
        if (!resizing)
            {
            return;
            }
        i32 cx = (i32)0;
        i32 cy = (i32)0;
        self.toCanvas(wx, wy, &cx, &cy);
        i32 dx = cx - rPressX;
        i32 dy = cy - rPressY;
        i32 w = (rCorner == (i32)1 || rCorner == (i32)3) ? rStartW + dx : rStartW - dx;
        i32 h = (rCorner == (i32)2 || rCorner == (i32)3) ? rStartH + dy : rStartH - dy;
        if (w < (i32)40)
            {
            w = (i32)40;
            }
        if (h < (i32)40)
            {
            h = (i32)40;
            }
        rNewW = w;
        rNewH = h;
        if (formResized)
            {
            formResized(w, h, false);
            }
        // The run loop is parked in trackDragStep, so repaint here to make the resize live.
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    void formEnd(void)
        {
        if (!resizing)
            {
            return;
            }
        resizing = false;
        if (formResized)
            {
            formResized(rNewW, rNewH, true);
            }
        }

    // ---- moving the form on the grid ------------------------------------------------------------
    void setFormMoved(callback f void(i32 offX, i32 offY, bool done))
        {
        formMoved = f;
        }
    // Window coordinates to RAW canvas coordinates: the overlay's own origin subtracted, but NOT
    // offX/offY.  A form move changes offX/offY, so it cannot measure its own steps in the form's
    // frame; it works in the raw canvas frame and reports the offset it lands on.
    void toCanvasRaw(i32 wx, i32 wy, i32* cx, i32* cy)
        {
        UXRect a = self.absoluteFrame();
        cx[0] = wx - (i32)a.x;
        cy[0] = wy - (i32)a.y;
        }
    // A press on the grip or the panel background: carry the form, modally where the toolkit owns the
    // loop (a slider, a split divider), else through mouseDragged / mouseUp.
    void formMoveBegin(i32 wx, i32 wy, UXEvent* e)
        {
        i32 rx = (i32)0;
        i32 ry = (i32)0;
        self.toCanvasRaw(wx, wy, &rx, &ry);
        mfRefX = rx;
        mfRefY = ry;
        mfOffX = offX;
        mfOffY = offY;
        movingForm = true;
        if (!gDriver.dragTrackingIsModal())
            {
            return; // mouseDragged / mouseUp carry it
            }
        i32 x = (i32)e.x;
        i32 y = (i32)e.y;
        while (gDriver.trackDragStep(&x, &y) != (i32)0)
            {
            self.formMoveStep(x, y);
            }
        self.formMoveEnd();
        }
    void formMoveStep(i32 wx, i32 wy)
        {
        if (!movingForm)
            {
            return;
            }
        i32 rx = (i32)0;
        i32 ry = (i32)0;
        self.toCanvasRaw(wx, wy, &rx, &ry);
        offX = mfOffX + (rx - mfRefX);
        offY = mfOffY + (ry - mfRefY);
        if (formMoved)
            {
            formMoved(offX, offY, false);
            }
        self.setNeedsDisplay();
        if (gApp != (UXApplication*)0)
            {
            gApp.displayIfNeeded();
            }
        }
    void formMoveEnd(void)
        {
        if (!movingForm)
            {
            return;
            }
        movingForm = false;
        if (formMoved)
            {
            formMoved(offX, offY, true);
            }
        self.setNeedsDisplay();
        }

    UXRscObject* currentSelection(void)
        {
        return selection;
        }
    void setSelection(UXRscObject* o)
        {
        selection = o;
        }
    void setRoot(UXRscObject* r)
        {
        drag.root = r;
        }
    }
