// RKMainController.xc — the main window's controller, written as a NIB CLIENT.
//
// This class constructs nothing.  It declares what it needs to talk to
// (`outlet`) and what it can be told (`:action`), and something else supplies
// the views: today RKMainBuilder, building them in code; later a nib that
// Rocks itself authored.  That is the whole bootstrap plan — swap the builder
// file, keep this one — and it only works if the controller never reaches out
// and makes a view for itself.
//
// The `outlet` / `:action` decorations auto-conform this class to
// UXDesignable, and the compiler synthesises setOutlet/wireAction from them
// (bug 026).  Both the code builder and the nib loader drive those SAME two
// methods, which is what makes the two paths interchangeable rather than
// merely similar.  It also means this file is the worked example of the
// pattern every Rocks user will write.
#import "UXDesignable.xc"
#import "UXControl.xc"
#import "UXOutlineView.xc"
#import "UXView.xc"
#import "RKModel.xc"
#import "RKCanvas.xc"
#import "RKOutline.xc"
#import "RKSelection.xc"
#import "RKInspector.xc"
#import "RKDrag.xc"
#import "UXMenu.xc"
#import "UXTableView.xc"

class RKMainController : Object<UXTableDelegate>
    {
    // ---- outlets: the views this controller talks to -----------------------
    outlet UXOutlineView* formOutline; // the document's forms and their trees
    outlet UXView* canvas;             // the drawing area (real UXKit widgets)
    outlet UXView* inspector;          // the property pane
    outlet UXLabel* statusLabel;       // one line of feedback, bottom left

    // The document.  The controller owns the MODEL; the canvas outlet shows it.
    RKResource* doc;
    i32 shownTree;
    RKOutline* outlineModel;    // strong: the outline view holds its source weakly
    RKCanvas* canvasMap;        // the map for the tree currently shown
    Array<UXView>* panes;       // one container per tree, built on first view
    Array<RKCanvas>* maps;      // its object -> widget map
    RKObject* selected;         // what the designer has picked, or 0
    RKSelectionFrame* selFrame; // the selection art; created once, moved around
    // The input surface that makes the canvas a DESIGN surface rather than a
    // live one.  It sits over every pane, so a click selects a button instead
    // of pressing it.  Created here, added to the canvas when there is one.
    RKEditOverlay* overlay;
    // The menu bar, so a toggle can put its own tick back.  Held weakly: the
    // application owns the bar, and a controller that owned its menus would be
    // a controller that built views.
    weak : UXMenuBar* menuBar;
    i32 viewMenu, snapItem, guideItem; // where the toggles live in that bar
    u8* geomBuf;                       // reused: a drag writes this per step
    // NOTE: `inspector` is the outlet for the PANE (a UXView); this is its
    // controller.  Two different things, so two different names.
    RKInspector* inspectorCtl;

    // ---- state -------------------------------------------------------------
    // Deliberately not a view: the controller owns MODEL state and asks the
    // views to show it, never the reverse.
    i32 selectedForm;
    bool dirty;

    void init(void)
        {
        selectedForm = (i32)-1;
        dirty = false;
        doc = (RKResource*)0;
        shownTree = (i32)0;
        outlineModel = new RKOutline();
        canvasMap = new RKCanvas();
        panes = new Array();
        maps = new Array();
        selected = (RKObject*)0;
        selFrame = (RKSelectionFrame*)0;
        overlay = new RKEditOverlay();
        overlay.picked = &self.onPick;
        overlay.changed = &self.onDragStep;
        overlay.ended = &self.onDragEnd;
        menuBar = (UXMenuBar*)0;
        viewMenu = (i32)-1;
        snapItem = (i32)0;
        guideItem = (i32)1;
        geomBuf = (u8*)malloc((u32)64);
        inspectorCtl = new RKInspector();
        inspectorCtl.changed = &self.onInspectorEdit;
        formOutline = (UXOutlineView*)0;
        canvas = (UXView*)0;
        inspector = (UXView*)0;
        statusLabel = (UXLabel*)0;
        }

    // ---- actions: what the UI can ask for ----------------------------------
    // Each is wired by NAME, so the builder and a nib reach them identically.
    void onNewForm(UXControl* sender) : action
        {
        self.say((u8*)"New form");
        }
    void onDelete(UXControl* sender) : action
        {
        self.say((u8*)"Delete");
        }
    void onDesktop(UXControl* sender) : action
        {
        self.say((u8*)"Variant: desktop");
        }
    void onTablet(UXControl* sender) : action
        {
        self.say((u8*)"Variant: tablet");
        }
    void onPhone(UXControl* sender) : action
        {
        self.say((u8*)"Variant: phone");
        }

    // Show a resource's tree on the canvas as REAL widgets.  Takes a parsed
    // model rather than a path: file I/O is the platform layer's job, and
    // keeping it out of here is what lets the controller build everywhere.
    //
    // Each tree gets its OWN container inside the canvas, built once and then
    // shown or hidden — the same swap UXTabView makes.  The alternative,
    // tearing the old widgets out, means removing children by index while the
    // indices are shifting underneath, and removeFromSuperview does not even
    // clear the parent's subview array; hiding is both safer and cheaper, and
    // it keeps a tree's selection state alive when the designer flips back.
    i32 showResource(RKResource* r, i32 treeIndex)
        {
        doc = r;
        if (r == (RKResource*)0 || canvas == (UXView*)0)
            {
            return (i32)0;
            }
        if (treeIndex < (i32)0 || treeIndex >= r.treeCount())
            {
            return (i32)0;
            }
        shownTree = treeIndex;

        // A selection points into ONE tree's widgets, so it does not survive
        // a switch — better to drop it than to leave a frame over the wrong
        // form.
        selected = (RKObject*)0;
        inspectorCtl.show((RKObject*)0);
        if (selFrame != (RKSelectionFrame*)0)
            {
            selFrame.setHidden(true);
            }

        while ((i32)panes.count() <= treeIndex)
            {
            UXView* pane = new UXView();
            canvas.addSubview(pane, canvas.bounds());
            RKCanvas* map = new RKCanvas();
            i32 built = map.realize(r.treeAt((i32)panes.count()), pane);
            panes.add(pane);
            maps.add(map);
            }
        for (i32 i = (i32)0; i < (i32)panes.count(); i = i + (i32)1)
            {
            ((UXView* ?)panes.get((u16)i)).setHidden(i != treeIndex);
            }
        canvasMap = (RKCanvas* ?)maps.get((u16)treeIndex);

        // The overlay edits ONE form at a time, so it follows the shown tree.
        overlay.setRoot(r.treeAt(treeIndex).root);
        overlay.setSelection((RKObject*)0);
        self.raiseOverlay();

        if (formOutline != (UXOutlineView*)0)
            {
            outlineModel.build(r);
            formOutline.setOutlineSource(outlineModel);
            formOutline.reloadData();
            }
        return (i32)canvasMap.objs.count();
        }

    // ---- selection ---------------------------------------------------------
    // The outline is a table underneath, so selection arrives as a ROW; the
    // row's item is the RKOutlineNode we put there, which is what makes the
    // two panes one editor rather than two independent views.
    void tableSelectionDidChange(UXTableView* t, i32 row)
        {
        if (formOutline == (UXOutlineView*)0)
            {
            return;
            }
        UXOutlineNode* vn = formOutline.nodeAt(row);
        if (vn == (UXOutlineNode*)0)
            {
            return;
            }
        RKOutlineNode* n = (RKOutlineNode* ?)vn.item;
        if (n == (RKOutlineNode*)0)
            {
            return;
            }

        // A TREE row switches the canvas; an OBJECT row selects within it.
        if (n.treeIndex >= (i32)0)
            {
            i32 count = self.showResource(doc, n.treeIndex);
            self.say(n.label);
            return;
            }
        self.selectObject(n.obj);
        self.say(n.label);
        }

    // Put the overlay over the object's widget.  Frames are parent-relative,
    // so the overlay's position is the widget's absolute frame less the
    // canvas's — the one place in Rocks that needs absolute coordinates.
    void selectObject(RKObject* o)
        {
        selected = o;
        inspectorCtl.show(o); // a NEW selection re-renders the pane
        self.placeFrame(o);
        }

    // Position the overlay over an object's widget, without touching the pane.
    void placeFrame(RKObject* o)
        {
        if (canvas == (UXView*)0)
            {
            return;
            }
        UXView* w = canvasMap.viewFor(o);
        if (w == (UXView*)0)
            {
            return;
            }
        UXRect wa = w.absoluteFrame();
        UXRect ca = canvas.absoluteFrame();
        if (selFrame != (RKSelectionFrame*)0)
            {
            selFrame.setHidden(false);
            }
        UXRect f = UXGeom.make((i16)((i32)wa.x - (i32)ca.x), (i16)((i32)wa.y - (i32)ca.y),
                               wa.w, wa.h);
        if (selFrame == (RKSelectionFrame*)0)
            {
            selFrame = new RKSelectionFrame();
            // The frame is drawn ABOVE the overlay so its handles show, which
            // means it is also what a press on a handle hits.  Forwarding
            // straight back to the overlay keeps one drag implementation
            // instead of a second one living in the selection art.
            selFrame.press = &overlay.mouseDown;
            canvas.addSubview(selFrame, f);
            }
        else
            {
            selFrame.setFrame(f);
            }
        selFrame.setNeedsDisplay();
        }

    RKObject* selectedObject(void)
        {
        return selected;
        }

    // ---- direct manipulation ------------------------------------------------

    // Put the input surface, and then the selection art, back on top.
    //
    // Order is not cosmetic here.  Panes are created lazily — one the first
    // time each form is shown — and both the driver's hit-test and AppKit's
    // pick the LAST matching sibling, so a pane added after the overlay would
    // sit in front of it and the real widgets would start eating clicks again.
    // The selection frame goes above the overlay so its handles are visible,
    // and forwards its own presses back down so grabbing a handle still works.
    void raiseOverlay(void)
        {
        if (canvas == (UXView*)0)
            {
            return;
            }
        overlay.removeFromSuperview();
        canvas.addSubview(overlay, canvas.bounds());
        if (selFrame != (RKSelectionFrame*)0)
            {
            UXRect f = selFrame.frame();
            selFrame.removeFromSuperview();
            canvas.addSubview(selFrame, f);
            }
        }

    // A press landed.  Nothing (bare form background) is a DESELECT, which is
    // what makes clicking away from a control feel right rather than sticky.
    void onPick(RKObject* o)
        {
        if (o == (RKObject*)0)
            {
            selected = (RKObject*)0;
            overlay.setSelection((RKObject*)0);
            inspectorCtl.show((RKObject*)0);
            if (selFrame != (RKSelectionFrame*)0)
                {
                selFrame.setHidden(true);
                }
            self.say((u8*)"—");
            return;
            }
        self.selectObject(o);
        overlay.setSelection(o);
        }

    // One step of a live drag.  The widget and the frame move; the INSPECTOR
    // does not, because rebuilding its rows mid-drag would throw away the very
    // fields the designer is about to read.  It catches up on release.
    void onDragStep(RKObject* o)
        {
        if (o == (RKObject*)0)
            {
            return;
            }
        dirty = true;
        UXView* w = canvasMap.viewFor(o);
        if (w != (UXView*)0)
            {
            w.setFrame(UXGeom.make((i16)o.x, (i16)o.y, (i16)o.w, (i16)o.h));
            }
        self.placeFrame(o);
        self.say(RKMainController.geomText(geomBuf, o));
        }

    void onDragEnd(RKObject* o)
        {
        if (o == (RKObject*)0)
            {
            return;
            }
        inspectorCtl.show(o); // the X/Y/W/H fields now read where it landed
        self.placeFrame(o);
        }

    // "20, 40   60 x 20" — the running read-out a designer actually watches
    // while dragging.  Written into a buffer the controller owns and reuses:
    // this runs once per pointer step, and a fresh allocation each time would
    // make a drag allocate hundreds of strings for no reason.
    static u8* geomText(u8* b, RKObject* o)
        {
        i32 n = (i32)0;
        n = RKMainController.put(b, n, RKInspector.fmtInt(o.x));
        n = RKMainController.put(b, n, (u8*)", ");
        n = RKMainController.put(b, n, RKInspector.fmtInt(o.y));
        n = RKMainController.put(b, n, (u8*)"   ");
        n = RKMainController.put(b, n, RKInspector.fmtInt(o.w));
        n = RKMainController.put(b, n, (u8*)" x ");
        n = RKMainController.put(b, n, RKInspector.fmtInt(o.h));
        b[n] = (u8)0;
        return b;
        }
    static i32 put(u8* b, i32 n, u8* s)
        {
        i32 i = (i32)0;
        while (s[i] != (u8)0 && n < (i32)62)
            {
            b[n] = s[i];
            n = n + (i32)1;
            i = i + (i32)1;
            }
        return n;
        }

    // ---- the toggles --------------------------------------------------------
    // Both start ON, which is the useful default: an editor whose snapping has
    // to be switched on is an editor whose first forms are all one pixel out.
    // They are menu items rather than a preference because the moment you need
    // them off is the moment you are fighting them, and that moment wants one
    // keystroke, not a dialog.
    void onToggleSnap(UXMenuItem* sender)
        {
        overlay.drag.snapOn = !overlay.drag.snapOn;
        self.reflectToggles();
        self.say(overlay.drag.snapOn ? (u8*)"Snap on" : (u8*)"Snap off");
        }
    void onToggleGuides(UXMenuItem* sender)
        {
        overlay.drag.guidesOn = !overlay.drag.guidesOn;
        self.reflectToggles();
        self.say(overlay.drag.guidesOn ? (u8*)"Guides on" : (u8*)"Guides off");
        }
    // The tick in the menu is a VIEW of the state, so it is redrawn from the
    // state rather than flipped alongside it — the two cannot drift apart.
    void reflectToggles(void)
        {
        if (menuBar == (UXMenuBar*)0 || viewMenu < (i32)0)
            {
            return;
            }
        menuBar.setChecked((u16)viewMenu, (u16)snapItem, overlay.drag.snapOn);
        menuBar.setChecked((u16)viewMenu, (u16)guideItem, overlay.drag.guidesOn);
        }
    bool snapEnabled(void)
        {
        return overlay.drag.snapOn;
        }
    bool guidesEnabled(void)
        {
        return overlay.drag.guidesOn;
        }

    // An inspector edit changed the MODEL; the canvas has to catch up.  Only
    // the one widget is touched rather than rebuilding the form: a rebuild
    // would destroy the very widget the designer is typing into, and take the
    // keyboard focus with it.
    void onInspectorEdit(RKObject* o)
        {
        if (o == (RKObject*)0 || canvas == (UXView*)0)
            {
            return;
            }
        dirty = true;
        UXView* w = canvasMap.viewFor(o);
        if (w != (UXView*)0)
            {
            w.setFrame(UXGeom.make((i16)o.x, (i16)o.y, (i16)o.w, (i16)o.h));
            RKCanvas.applyState(w, o); // enabled, hidden, checked, selected
            RKCanvas.applyText(w, o);
            w.setNeedsDisplay();
            }
        // Move the frame, but do NOT re-show the inspector: the edit came FROM
        // it, and show() rebuilds every row — destroying the widget being
        // typed into and taking the keyboard focus with it.  Same rule as the
        // canvas, in the other direction.
        self.placeFrame(o);
        }

    // A form factor with NO variant reads "no layout — create one", never
    // "inheriting desktop" (UXNB-V2 §1): the chain is a runtime last resort,
    // not a design relationship, and the editor must not teach otherwise.
    void say(u8* msg)
        {
        if (statusLabel != (UXLabel*)0)
            {
            statusLabel.setText(msg);
            }
        }
    }
