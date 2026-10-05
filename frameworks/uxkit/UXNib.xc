// UXNib.xc — load a form from a .rsc document as UXKit views, on every backend.
//
// The document is the one Rocks edits (UXRscModel): classic GEM trees, one per layout theme of a
// form, and the nib chunk after them (docs/UXNB-V2.md): logical ids, class overrides, top-level
// objects and the outlet/action connections, each scoped to the themes it binds in.  Loading a
// form picks the theme for this device (the driver's form factor and orientation, down the
// fallback chain), builds that tree as real UXKit controls, makes the top-level objects, binds
// the connections in scope through the logical ids, and sends awakeFromNib.
//
// The type -> control mapping here is the designer's too: Rocks' canvas builds its forms through
// UXNib.viewFor, so what the designer shows is what an app loads.
//
// (UXNibGem is the older GEM-only loader, binding views onto libGEM's own OBJECT array.)
#import "Array.xc"
#import "UXView.xc"
#import "UXViewTree.xc"
#import "UXControl.xc"
#import "UXGroupBox.xc"
#import "UXPopUpButton.xc"
#import "UXGeometry.xc"
#import "UXDesignable.xc"
#import "UXViewDriver.xc"
#import "UXRscModel.xc"
#import "UXRscRead.xc"
#import "UXNibV2.xc"

// A nib instantiates app objects BY CLASS NAME: custom view subclasses (for a named G_USERDEF) and
// non-view top-level objects (controllers, formatters).  Each MODULE that owns designable classes
// contributes a compiler-generated factory `xgNibNew(name) -> Object*` — a switch over ITS classes,
// returning null for a name it doesn't own — and REGISTERS it here.  The loader tries each registered
// factory in turn (per-module arm), so designable classes can live across the app + libraries without
// any module knowing another's classes.  A single-module app registers one.
//
// One factory returning Object* covers both kinds: the loader downcasts `(UXView* ?)` for a view and
// `(UXDesignable* ?)` for wiring.  (COMPILER-THREAD #9 — the Object* <-> protocol bridge — landed, so
// the earlier two-typed-factory workaround is gone, and a designable VIEW can now be an outlet owner
// or action target.)
typedef Object* UXNibFactory(u8* name); // a class name -> a fresh instance, or null if not ours
pointer gUXNibFn[8];
i32 gUXNibNFn;


// An object that wants to finish setting up once its outlets are connected.  The loader sends it
// to every object it made and to File's Owner, after all the wiring.
protocol UXNibAwaking
    {
    void awakeFromNib(void);
    }

// One loaded form: its views, its top-level objects, and what happened to its connections.
class UXNibInstance : Object
    {
    UXView* root;    // the form's root box, sized to it
    UXViewTree* viewTree; // the tree the views live in when the form was not loaded into a container
    UXRscTree* tree; // the layout that loaded
    i32 formId;
    i32 klass;       // the theme that loaded: UX_FORM_*
    i32 orient;      // UX_ORIENT_*
    Array<UXRscObject>* objs;
    Array<UXView>* views;
    Array<Object>* tops;
    Array<UXRscTopObject>* topRecs;
    i32 bound;      // connections made
    i32 skipped;    // in scope, but an end is not in this layout (the layout dropped that control)
    i32 outOfScope; // scoped to other themes

    void init(void)
        {
        root = (UXView*)0;
        viewTree = (UXViewTree*)0;
        tree = (UXRscTree*)0;
        objs = new Array();
        views = new Array();
        tops = new Array();
        topRecs = new Array();
        }

    // The view built for an object of the loaded tree, or 0.
    UXView* viewFor(UXRscObject* o)
        {
        for (u32 i = (u32)0; i < objs.count(); i = i + (u32)1)
            {
            if ((UXRscObject* ?)objs.get(i) == o)
                { return (UXView* ?)views.get(i);
                }
            }
        return (UXView*)0;
        }
    // The view for a logical control, or 0 when this layout omits it.
    UXView* viewForLogical(i32 logicalId)
        {
        if (logicalId == (i32)0)
            {
            return (UXView*)0;
            }
        for (u32 i = (u32)0; i < objs.count(); i = i + (u32)1)
            {
            if (((UXRscObject* ?)objs.get(i)).logicalId == logicalId)
                { return (UXView* ?)views.get(i);
                }
            }
        return (UXView*)0;
        }
    i32 topObjectCount(void)
        {
        return (i32)tops.count();
        }
    Object* topObjectAt(i32 i)
        { return (Object* ?)tops.get((u32)i);
        }
    // A top-level object by its id, or 0.
    Object* topObject(i32 id)
        {
        for (u32 i = (u32)0; i < topRecs.count(); i = i + (u32)1)
            {
            if (((UXRscTopObject* ?)topRecs.get(i)).id == id)
                { return (Object* ?)tops.get(i);
                }
            }
        return (Object*)0;
        }
    }

class UXNib
    {
    // Each module registers its generated `xgNibNew` factory once (the compiler emits this call in an
    // .init_array entry; explicit registration is the fallback).  registerViewFactory is a deprecated
    // alias kept so older callers still link — there is one factory list now.
    static void registerObjectFactory(pointer fn)
        {
        if (gUXNibNFn < (i32)8)
            {
            gUXNibFn[gUXNibNFn] = fn;
            gUXNibNFn = gUXNibNFn + (i32)1;
            }
        }
    static void registerViewFactory(pointer fn)
        {
        UXNib.registerObjectFactory(fn);
        }

    // Instantiate a designable class by name, trying each registered factory (Object* per #9).
    static Object* make(u8* cls)
        {
        for (i32 i = (i32)0; i < gUXNibNFn; i = i + (i32)1)
            {
            UXNibFactory* f = (UXNibFactory*)gUXNibFn[i];
            Object* o = f(cls);
            if (o != (Object*)0)
                {
                return o;
                }
            }
        return (Object*)0;
        }

    // ---- loading -------------------------------------------------------------------------------
    // From .rsc bytes, for this device's theme, into `into` (a window's content view, say): the
    // form's root becomes a subview at the container's origin.  With no container the form gets a
    // view tree of its own (ni.viewTree).  0 if the bytes are not a resource or there is no such
    // form.
    static UXNibInstance* load(u8* bytes, i32 n, i32 formId, UXDesignable* owner, UXView* into)
        {
        UXRscDoc* doc = UXRscReader.read(bytes, n);
        return doc != (UXRscDoc*)0 ? UXNib.loadDoc(doc, formId, owner, into) : (UXNibInstance*)0;
        }
    static UXNibInstance* loadDoc(UXRscDoc* doc, i32 formId, UXDesignable* owner, UXView* into)
        {
        i32 klass = (i32)UX_FORM_DESKTOP;
        i32 orient = (i32)UX_ORIENT_NONE;
        if (gDriver != (UXViewDriver*)0)
            {
            klass = gDriver.formFactorClass();
            orient = gDriver.orientation();
            }
        return UXNib.loadDocAs(doc, formId, klass, orient, owner, into);
        }
    // For a given theme: what a test, or the designer's preview, asks for.
    static UXNibInstance* loadDocAs(UXRscDoc* doc, i32 formId, i32 klass, i32 orient, UXDesignable* owner,
                                    UXView* into)
        {
        i32 gotClass = (i32)0;
        i32 gotOrient = (i32)0;
        UXRscTree* t = UXNib.selectTree(doc, formId, klass, orient, &gotClass, &gotOrient);
        if (t == (UXRscTree*)0 || t.root == (UXRscObject*)0)
            {
            return (UXNibInstance*)0;
            }
        UXNibInstance* ni = new UXNibInstance();
        ni.tree = t;
        ni.formId = formId;
        ni.klass = gotClass;
        ni.orient = gotOrient;
        i32 treeIndex = doc.indexOfTree(t);

        // views: the root box is the form's own view; its children are built into it
        // (a plain view unless its class is overridden: the window draws the form's background)
        u8* rootCls = UXNib.classFor(doc, formId, treeIndex, t.root, (i32)0);
        UXView* rv = (UXView*)0;
        if (rootCls != (u8*)0)
            { rv = (UXView* ?)UXNib.make(rootCls);
            }
        if (rv == (UXView*)0)
            {
            rv = new UXView();
            }
        UXRect rf = UXGeom.make((i16)0, (i16)0, (i16)t.root.w, (i16)t.root.h);
        if (into != (UXView*)0)
            {
            into.addSubview(rv, rf);
            }
        else
            {
            ni.viewTree = new UXViewTree();
            rv.attachTo(ni.viewTree, rf);
            }
        ni.root = rv;
        ni.objs.add(t.root);
        ni.views.add(rv);
        Array<UXRscObject>* order = t.allObjects(); // pre-order: the index a space-0 Ref names
        for (i32 i = (i32)0; i < t.root.childCount(); i = i + (i32)1)
            {
            UXNib.build(doc, ni, order, treeIndex, t.root.childAt(i), rv);
            }

        // top-level objects: the document's, made on every load
        for (u32 i = (u32)0; i < doc.topObjects.count(); i = i + (u32)1)
            {
            UXRscTopObject* rec = (UXRscTopObject* ?)doc.topObjects.get(i);
            Object* o = UXNib.make(rec.cls);
            if (o != (Object*)0)
                {
                ni.tops.add(o);
                ni.topRecs.add(rec);
                }
            }

        // connections in scope whose ends are in this layout
        for (u32 i = (u32)0; i < doc.connections.count(); i = i + (u32)1)
            {
            UXRscConnection* c = (UXRscConnection* ?)doc.connections.get(i);
            if (!UXNib.concerns(doc, c, formId))
                {
                continue;
                }
            if (!c.inScope(gotClass, gotOrient))
                {
                ni.outOfScope = ni.outOfScope + (i32)1;
                continue;
                }
            Object* src = UXNib.resolve(ni, order, treeIndex, c.src, owner);
            Object* dst = UXNib.resolve(ni, order, treeIndex, c.dst, owner);
            if (src == (Object*)0 || dst == (Object*)0)
                {
                ni.skipped = ni.skipped + (i32)1;
                continue;
                }
            bool ok = false;
            if (c.kind == (i32)UXR_CONN_OUTLET)
                {
                UXDesignable* ud = (UXDesignable* ?)src;
                if (ud != (UXDesignable*)0)
                    {
                    ok = ud.setOutlet(c.member, dst);
                    }
                }
            else
                {
                UXDesignable* ud = (UXDesignable* ?)dst;
                UXControl* ctl = (UXControl* ?)src;
                if (ud != (UXDesignable*)0 && ctl != (UXControl*)0)
                    {
                    ok = ud.wireAction(c.member, ctl);
                    }
                }
            if (ok)
                {
                ni.bound = ni.bound + (i32)1;
                }
            else
                {
                ni.skipped = ni.skipped + (i32)1;
                }
            }

        // awakeFromNib: the objects made here, then File's Owner
        for (u32 i = (u32)0; i < ni.tops.count(); i = i + (u32)1)
            {
            UXNib.awake((Object* ?)ni.tops.get(i));
            }
        for (u32 i = (u32)0; i < ni.views.count(); i = i + (u32)1)
            {
            UXNib.awake((Object* ?)ni.views.get(i));
            }
        UXNib.awake((Object*)owner);
        return ni;
        }

    static void awake(Object* o)
        {
        UXNibAwaking* a = (UXNibAwaking* ?)o;
        if (a != (UXNibAwaking*)0)
            {
            a.awakeFromNib();
            }
        }

    static void build(UXRscDoc* doc, UXNibInstance* ni, Array<UXRscObject>* order, i32 treeIndex,
                      UXRscObject* o, UXView* parent)
        {
        UXView* v = UXNib.viewFor(o, UXNib.classFor(doc, ni.formId, treeIndex, o, UXNib.indexIn(order, o)));
        parent.addSubview(v, UXGeom.make((i16)o.x, (i16)o.y, (i16)o.w, (i16)o.h));
        UXNib.applyState(v, o);
        ni.objs.add(o);
        ni.views.add(v);
        for (i32 i = (i32)0; i < o.childCount(); i = i + (i32)1)
            {
            UXNib.build(doc, ni, order, treeIndex, o.childAt(i), v);
            }
        }

    static i32 indexIn(Array<UXRscObject>* order, UXRscObject* o)
        {
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            {
            if ((UXRscObject* ?)order.get(i) == o)
                {
                return (i32)i;
                }
            }
        return (i32)-1;
        }

    // The form a tree belongs to is looked up by formId: a multi-variant form's id, or, for a tree
    // in no form, the tree's own index (a single `any` layout).
    static UXRscTree* selectTree(UXRscDoc* doc, i32 formId, i32 klass, i32 orient, i32* gotClass, i32* gotOrient)
        {
        gotClass[0] = (i32)-1;
        gotOrient[0] = (i32)UX_ORIENT_NONE;
        UXRscForm* f = doc.formById(formId);
        if (f == (UXRscForm*)0)
            {
            if (formId < (i32)0 || formId >= doc.treeCount() || doc.formOf(doc.treeAt(formId)) != (UXRscForm*)0)
                {
                return (UXRscTree*)0;
                }
            gotClass[0] = (i32)UX_FORM_ANY;
            return doc.treeAt(formId);
            }
        i32 other = orient == (i32)UX_ORIENT_PORTRAIT ? (i32)UX_ORIENT_LANDSCAPE
                  : (orient == (i32)UX_ORIENT_LANDSCAPE ? (i32)UX_ORIENT_PORTRAIT : (i32)-1);
        for (i32 step = (i32)0; step < (i32)4; step = step + (i32)1)
            {
            i32 want = UXNibV2.chain(klass, step);
            // pass 0: this orientation; 1: none; 2: the other one (or, for NONE, anything)
            for (i32 pass = (i32)0; pass < (i32)3; pass = pass + (i32)1)
                {
                for (i32 v = (i32)0; v < f.variantCount(); v = v + (i32)1)
                    {
                    UXRscVariant* va = f.variantAt(v);
                    if (va.klass != want)
                        {
                        continue;
                        }
                    bool take = pass == (i32)0 ? (va.orient == orient)
                              : (pass == (i32)1 ? (va.orient == (i32)UX_ORIENT_NONE) : (other < (i32)0 || va.orient == other));
                    if (take)
                        {
                        gotClass[0] = want;
                        gotOrient[0] = va.orient;
                        return va.tree;
                        }
                    }
                }
            }
        return (UXRscTree*)0;
        }

    // Whether a connection belongs to this form: a view end must be one of its controls.  One with
    // no view end (owner to a top object) belongs to every form.
    static bool concerns(UXRscDoc* doc, UXRscConnection* c, i32 formId)
        {
        return UXNib.refConcerns(doc, c.src, formId) && UXNib.refConcerns(doc, c.dst, formId);
        }
    static bool refConcerns(UXRscDoc* doc, UXRscRef* r, i32 formId)
        {
        if (r.space == (i32)UXR_REF_LOGICAL)
            {
            return r.a == formId;
            }
        if (r.space == (i32)UXR_REF_VIEW)
            {
            if (r.a < (i32)0 || r.a >= doc.treeCount())
                {
                return false;
                }
            UXRscForm* f = doc.formOf(doc.treeAt(r.a));
            return f != (UXRscForm*)0 ? f.formId == formId : r.a == formId;
            }
        return true;
        }

    static Object* resolve(UXNibInstance* ni, Array<UXRscObject>* order, i32 treeIndex, UXRscRef* r, UXDesignable* owner)
        {
        if (r.space == (i32)UXR_REF_LOGICAL)
            {
            return (Object* ?)ni.viewForLogical(r.b);
            }
        if (r.space == (i32)UXR_REF_VIEW)
            {
            if (r.a != treeIndex || r.b < (i32)0 || r.b >= (i32)order.count())
                {
                return (Object*)0;
                }
            return (Object* ?)ni.viewFor((UXRscObject* ?)order.get((u32)r.b));
            }
        if (r.space == (i32)UXR_REF_TOP)
            {
            return ni.topObject(r.a);
            }
        if (r.space == (i32)UXR_REF_OWNER)
            {
            return (Object*)owner;
            }
        return (Object*)0; // First Responder: not bound at load
        }

    // The class a control is overridden to, or 0: by logical id, or (single-variant) by position.
    static u8* classFor(UXRscDoc* doc, i32 formId, i32 treeIndex, UXRscObject* o, i32 objIndex)
        {
        for (u32 i = (u32)0; i < doc.classOverrides.count(); i = i + (u32)1)
            {
            UXRscClassOverride* co = (UXRscClassOverride* ?)doc.classOverrides.get(i);
            UXRscRef* r = co.view;
            if (r.space == (i32)UXR_REF_LOGICAL && r.a == formId && o.logicalId != (i32)0 && r.b == o.logicalId)
                {
                return co.cls;
                }
            if (r.space == (i32)UXR_REF_VIEW && r.a == treeIndex && r.b == objIndex)
                {
                return co.cls;
                }
            }
        return (u8*)0;
        }

    // ---- one object -> one UXKit view ------------------------------------------------------------
    // A class override wins when a factory makes it; otherwise the GEM type decides.  Where the
    // toolkit has no equivalent the object becomes a VISIBLE placeholder titled with its class or
    // type: an invisible stand-in is a silent hole in the form.
    static UXView* viewFor(UXRscObject* o, u8* cls)
        {
        if (cls != (u8*)0 && cls[0] != (u8)0)
            {
            UXView* cv = (UXView* ?)UXNib.make(cls);
            if (cv != (UXView*)0)
                {
                return cv;
                }
            }
        i32 t = o.type;
        if (t == (i32)UXR_T_BUTTON)
            {
            UXButton* b = new UXButton();
            b.setTitle(UXNib.textOf(o));
            return (UXView*)b;
            }
        if (t == (i32)UXR_T_CHECKBOX)
            {
            UXCheckbox* c = new UXCheckbox();
            c.setTitle(UXNib.textOf(o));
            c.setChecked((o.state & (i32)UXR_S_CHECKED) != (i32)0);
            return (UXView*)c;
            }
        if (t == (i32)UXR_T_RADIO)
            {
            UXRadioButton* r = new UXRadioButton();
            r.setTitle(UXNib.textOf(o));
            r.setSelected((o.state & (i32)UXR_S_SELECTED) != (i32)0);
            return (UXView*)r;
            }
        if (t == (i32)UXR_T_STRING || t == (i32)UXR_T_TEXT || t == (i32)UXR_T_TITLE)
            {
            UXLabel* l = new UXLabel();
            l.setTitle(UXNib.textOf(o));
            return (UXView*)l;
            }
        if (t == (i32)UXR_T_FIELD || t == (i32)UXR_T_FTEXT ||
            t == (i32)UXR_T_BOXTEXT || t == (i32)UXR_T_FBOXTEXT)
            {
            UXTextField* f = new UXTextField();
            if (o.ted != (UXRscTedinfo*)0)
                {
                f.setText(o.ted.text);
                }
            return (UXView*)f;
            }
        if (t == (i32)UXR_T_POPUP)
            {
            // A GEM popup's spec is its label; the menu behind it lives in a linked tree.  Showing
            // the control with its current value beats a hole in the form.
            UXPopUpButton* p = new UXPopUpButton();
            p.addItem(UXNib.textOf(o), (i32)0);
            p.selectItem((i32)0);
            return (UXView*)p;
            }
        if (t == (i32)UXR_T_BOX || t == (i32)UXR_T_BOXCHAR)
            {
            // A visible box with children reads as a group; an empty one is just a panel.
            UXGroupBox* g = new UXGroupBox();
            g.setTitle((u8*)"");
            return (UXView*)g;
            }
        // IBOX is an INVISIBLE box: a grouping rectangle with no chrome.
        if (t == (i32)UXR_T_IBOX)
            {
            return new UXView();
            }
        UXGroupBox* unknown = new UXGroupBox();
        unknown.setTitle(cls != (u8*)0 && cls[0] != (u8)0 ? cls : UXNib.typeName(o.type));
        return (UXView*)unknown;
        }

    // A short name for a type, for placeholders and the designer's outline.
    static u8* typeName(i32 t)
        {
        if (t == (i32)UXR_T_BOX)
            {
            return (u8*)"box";
            }
        if (t == (i32)UXR_T_TEXT)
            {
            return (u8*)"text";
            }
        if (t == (i32)UXR_T_BOXTEXT)
            {
            return (u8*)"boxtext";
            }
        if (t == (i32)UXR_T_IMAGE)
            {
            return (u8*)"image";
            }
        if (t == (i32)UXR_T_USERDEF)
            {
            return (u8*)"userdef";
            }
        if (t == (i32)UXR_T_IBOX)
            {
            return (u8*)"ibox";
            }
        if (t == (i32)UXR_T_BUTTON)
            {
            return (u8*)"button";
            }
        if (t == (i32)UXR_T_BOXCHAR)
            {
            return (u8*)"boxchar";
            }
        if (t == (i32)UXR_T_STRING)
            {
            return (u8*)"string";
            }
        if (t == (i32)UXR_T_FTEXT)
            {
            return (u8*)"ftext";
            }
        if (t == (i32)UXR_T_FBOXTEXT)
            {
            return (u8*)"fboxtext";
            }
        if (t == (i32)UXR_T_ICON)
            {
            return (u8*)"icon";
            }
        if (t == (i32)UXR_T_TITLE)
            {
            return (u8*)"title";
            }
        if (t == (i32)UXR_T_CICONBLK)
            {
            return (u8*)"ciconblk";
            }
        if (t == (i32)UXR_T_CHECKBOX)
            {
            return (u8*)"checkbox";
            }
        if (t == (i32)UXR_T_RADIO)
            {
            return (u8*)"radio";
            }
        if (t == (i32)UXR_T_POPUP)
            {
            return (u8*)"popup";
            }
        if (t == (i32)UXR_T_FIELD)
            {
            return (u8*)"field";
            }
        if (t == (i32)UXR_T_CICON)
            {
            return (u8*)"cicon";
            }
        return (u8*)"?";
        }

    // Push an object's STATE into the widget realized for it.
    //
    // ONE place, called both when a form is first realized and after every
    // edit.  It used to be three -- widgetFor set the toggles at creation,
    // realizeInto did enabled/hidden, and the controller's edit path did its
    // own subset -- and each time a property was added the three drifted a
    // little further.  That is how "Hidden" reached the model and never the
    // screen, and then how "Selected" on a radio did the same: the code that
    // built a form knew about it and the code that edited one did not.
    //
    // Adding a property now means adding it HERE, and both paths get it.
    static void applyState(UXView* w, UXRscObject* o)
        {
        if (w == (UXView*)0 || o == (UXRscObject*)0)
            {
            return;
            }
        w.setEnabled((o.state & (i32)UXR_S_DISABLED) == (i32)0);
        w.setHidden((o.flags & (i32)UXR_F_HIDETREE) != (i32)0);
        // Text alignment, straight through: UX_ALIGN_* is numbered to match
        // GEM's te_just, so there is nothing to convert.  It used to need a
        // three-way map, which is one more thing that can be got backwards --
        // and getting it backwards swaps RIGHT and CENTRE, which looks nearly
        // correct and would write the wrong value into every .rsc Rocks saved.
        if (o.ted != (UXRscTedinfo*)0)
            { ((UXControl* ?)w).setAlignment(o.ted.just);
            }
        i32 k = (i32)w.kind();
        if (k == (i32)UXKindCheckbox)
            {
            ((UXCheckbox* ?)w).setChecked((o.state & (i32)UXR_S_CHECKED) != (i32)0);
            }
        else if (k == (i32)UXKindRadio)
            {
            ((UXRadioButton* ?)w).setSelected((o.state & (i32)UXR_S_SELECTED) != (i32)0);
            }
        }

    // Push an object's text into the widget already realized for it.  The
    // alternative — rebuild the widget — would destroy the control the
    // designer is typing into, along with the keyboard focus.
    static void applyText(UXView* w, UXRscObject* o)
        {
        u8* t = UXNib.textOf(o);
        i32 k = (i32)w.kind();
        if (k == (i32)UXKindField)
            { ((UXTextField* ?)w).setText(t);
            return;
            }
        if (k == (i32)UXKindButton || k == (i32)UXKindLabel ||
            k == (i32)UXKindCheckbox || k == (i32)UXKindRadio)
            {
            ((UXControl* ?)w).setTitle(t);
            }
        }

    static u8* textOf(UXRscObject* o)
        {
        if (o.text != (u8*)0)
            {
            return o.text;
            }
        if (o.ted != (UXRscTedinfo*)0 && o.ted.text != (u8*)0)
            {
            return o.ted.text;
            }
        return (u8*)"";
        }
    }
