// RKCanvas.xc — the resource model, realized as REAL UXKit widgets.
//
// This is the payoff for writing Rocks in XC.  A GEM object tree becomes an
// actual UXView tree of actual UXButtons and UXTextFields, so the canvas is
// not a drawing OF the UI, it IS the UI — the same widget objects, through the
// same drivers, that the edited application will run.  There is no second
// renderer to keep in step, which is the failure mode this whole rewrite was
// chosen to avoid: seven platforms were made to agree on how a radio button
// looks exactly once, and the editor inherits that rather than re-deriving it.
//
// Coordinates need no translation.  A GEM child's x/y are relative to its
// parent, and so are a UXView subview's, so the nesting maps straight across.
//
// Deliberately NEUTRAL: no file I/O, no driver calls, no Rocks state.  It takes
// a model and returns views, which keeps it buildable on every target and
// testable headlessly.
#import "UXView.xc"
#import "UXControl.xc"
#import "UXGroupBox.xc"
#import "UXPopUpButton.xc"
#import "UXGeometry.xc"
#import "UXRscModel.xc"
#import "UXRsc.xc"

class RKCanvas : Object
    {
    // The object -> widget map, kept as two parallel arrays.  Selection needs
    // it: clicking an outline row has to find the widget that row stands for,
    // and rediscovering it by walking two trees in step would re-derive at
    // every click something realize() already knew for free.
    Array<UXRscObject>* objs;
    Array<UXView>* views;
    // The document and the layout being realized, so a control is the class the document gives it
    // and has the settings its attributes hold; 0 = types only.
    UXRscDoc* doc;
    UXRscTree* tree;
    i32 theme;

    void init(void)
        {
        objs = new Array();
        views = new Array();
        doc = (UXRscDoc*)0;
        tree = (UXRscTree*)0;
        theme = (i32)UXR_ATTR_SHARED;
        }
    // Realize `t` of `d`, with classes and attributes: what UXRsc would load.
    i32 realizeIn(UXRscDoc* d, UXRscTree* t, i32 th, UXView* into)
        {
        doc = d;
        tree = t;
        theme = th;
        return self.realize(t, into);
        }

    // The widget realized for an object, or 0 if it was not realized (the
    // form's root, or a tree that is not the one on screen).
    UXView* viewFor(UXRscObject* o)
        {
        for (i32 i = (i32)0; i < (i32)objs.count(); i = i + (i32)1)
            {
            if ((UXRscObject* ?)objs.get((u16)i) == o)
                { return (UXView* ?)views.get((u16)i);
                }
            }
        return (UXView*)0;
        }

    // Build `tree` into `into`, which is normally the canvas outlet.  Returns
    // the number of widgets realized, so a caller can report "12 objects" and
    // a test can assert the whole tree arrived rather than most of it.
    i32 realize(UXRscTree* tree, UXView* into)
        {
        if (tree == (UXRscTree*)0 || tree.root == (UXRscObject*)0 || into == (UXView*)0)
            {
            return (i32)0;
            }
        // The root box is the form's own background: its children are what the
        // designer sees, so realize those INTO the canvas rather than nesting
        // one redundant container.
        objs = new Array();
        views = new Array();
        i32 n = (i32)0;
        for (i32 i = (i32)0; i < tree.root.childCount(); i = i + (i32)1)
            {
            n = n + self.realizeInto(tree.root.childAt(i), into);
            }
        return n;
        }

    i32 realizeInto(UXRscObject* o, UXView* parent)
        {
        UXView* v = (UXView*)0;
        if (doc != (UXRscDoc*)0 && tree != (UXRscTree*)0)
            {
            v = UXRsc.viewFor(o, doc.classOf(tree, o));
            }
        else
            {
            v = RKCanvas.widgetFor(o);
            }
        if (v == (UXView*)0)
            {
            return (i32)0;
            }
        parent.addSubview(v, UXGeom.make((i16)o.x, (i16)o.y, (i16)o.w, (i16)o.h));
        // The designer should see the state they set, not a uniformly live
        // form — so disabled objects look disabled, HIDETREE objects are
        // actually hidden, and a selected radio shows selected.  Hiding is
        // recoverable: the object still has its row in the outline, so it can
        // be selected and un-hidden there.  That escape hatch is what makes
        // honouring it safe rather than a trap.
        UXRsc.applyState(v, o);
        if (doc != (UXRscDoc*)0 && tree != (UXRscTree*)0)
            {
            UXRsc.applyAttrs(v, doc, doc.formIdOf(tree), o.logicalId, theme);
            }
        objs.add(o);
        views.add(v);
        i32 n = (i32)1;
        for (i32 i = (i32)0; i < o.childCount(); i = i + (i32)1)
            {
            n = n + self.realizeInto(o.childAt(i), v);
            }
        return n;
        }

    // One object -> one UXKit widget, by UXKit's own loader: the canvas shows what an app loads.
    static UXView* widgetFor(UXRscObject* o)
        {
        return UXRsc.viewFor(o, (u8*)0);
        }
    }
