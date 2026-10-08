// UXRsc.xc — load a form from a .rsc document as UXKit views, on every backend.
//
// The document is the one Rocks edits (UXRscModel): classic GEM trees, one per layout theme of a
// form, and the rsc chunk after them (docs/UXNB-V2.md): logical ids, class overrides, top-level
// objects and the outlet/action connections, each scoped to the themes it binds in.  Loading a
// form picks the theme for this device (the driver's form factor and orientation, down the
// fallback chain), builds that tree as real UXKit controls, makes the top-level objects, binds
// the connections in scope through the logical ids, and sends awakeFromRsc.
//
// The type -> control mapping here is the designer's too: Rocks' canvas builds its forms through
// UXRsc.viewFor, so what the designer shows is what an app loads.
//
// (UXRscGem is the older GEM-only loader, binding views onto libGEM's own OBJECT array.)
#import "Array.xc"
#import "UXView.xc"
#import "UXViewTree.xc"
#import "UXControl.xc"
#import "UXGroupBox.xc"
#import "UXPopUpButton.xc"
#import "UXSlider.xc"
#import "UXStepper.xc"
#import "UXProgressBar.xc"
#import "UXSegmentedControl.xc"
#import "UXComboBox.xc"
#import "UXTextView.xc"
#import "UXDatePicker.xc"
#import "UXBreadcrumb.xc"
#import "UXTableView.xc"
#import "UXScrollView.xc"
#import "UXSplitView.xc"
#import "UXOutlineView.xc"
#import "UXCollectionView.xc"
#import "UXGeometry.xc"
#import "UXDesignable.xc"
#import "UXViewDriver.xc"
#import "UXRscModel.xc"
#import "UXRscRead.xc"
#import "UXRscV2.xc"

// An rsc file instantiates app objects BY CLASS NAME: custom view subclasses (for a named G_USERDEF) and
// non-view top-level objects (controllers, formatters).  Each MODULE that owns designable classes
// contributes a compiler-generated factory `xgRscNew(name) -> Object*` — a switch over ITS classes,
// returning null for a name it doesn't own — and REGISTERS it here.  The loader tries each registered
// factory in turn (per-module arm), so designable classes can live across the app + libraries without
// any module knowing another's classes.  A single-module app registers one.
//
// One factory returning Object* covers both kinds: the loader downcasts `(UXView* ?)` for a view and
// `(UXDesignable* ?)` for wiring.  (COMPILER-THREAD #9 — the Object* <-> protocol bridge — landed, so
// the earlier two-typed-factory workaround is gone, and a designable VIEW can now be an outlet owner
// or action target.)
typedef Object* UXRscFactory(u8* name); // a class name -> a fresh instance, or null if not ours
pointer gUXRscFn[8];
i32 gUXRscNFn;


// An object that wants to finish setting up once its outlets are connected.  The loader sends it
// to every object it made and to File's Owner, after all the wiring.
protocol UXRscAwaking
    {
    void awakeFromRsc(void);
    }

// One loaded form: its views, its top-level objects, and what happened to its connections.
class UXRscInstance : Object
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

class UXRsc
    {
    // Each module registers its generated `xgRscNew` factory once (the compiler emits this call in an
    // .init_array entry; explicit registration is the fallback).  registerViewFactory is a deprecated
    // alias kept so older callers still link — there is one factory list now.
    static void registerObjectFactory(pointer fn)
        {
        if (gUXRscNFn < (i32)8)
            {
            gUXRscFn[gUXRscNFn] = fn;
            gUXRscNFn = gUXRscNFn + (i32)1;
            }
        }
    static void registerViewFactory(pointer fn)
        {
        UXRsc.registerObjectFactory(fn);
        }

    // Instantiate a designable class by name, trying each registered factory (Object* per #9),
    // then UXKit's own view classes.
    static Object* make(u8* cls)
        {
        for (i32 i = (i32)0; i < gUXRscNFn; i = i + (i32)1)
            {
            UXRscFactory* f = (UXRscFactory*)gUXRscFn[i];
            Object* o = f(cls);
            if (o != (Object*)0)
                {
                return o;
                }
            }
        return UXRsc.makeUXKit(cls);
        }
    // UXKit's controls that GEM has no type for, which a document holds as a G_USERDEF of that
    // class, with their settings in its attributes.
    static Object* makeUXKit(u8* cls)
        {
        if (UXRscDoc.seq(cls, (u8*)"UXSlider"))
            {
            return (Object*)new UXSlider();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXStepper"))
            {
            return (Object*)new UXStepper();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXProgressBar"))
            {
            return (Object*)new UXProgressBar();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXSegmentedControl"))
            {
            return (Object*)new UXSegmentedControl();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXComboBox"))
            {
            return (Object*)new UXComboBox();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXTextView"))
            {
            return (Object*)new UXTextView();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXDatePicker"))
            {
            return (Object*)new UXDatePicker();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXBreadcrumb"))
            {
            return (Object*)new UXBreadcrumb();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXTableView"))
            {
            return (Object*)new UXTableView();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXOutlineView"))
            {
            return (Object*)new UXOutlineView();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXCollectionView"))
            {
            return (Object*)new UXCollectionView();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXScrollView"))
            {
            return (Object*)new UXScrollView();
            }
        if (UXRscDoc.seq(cls, (u8*)"UXSplitView"))
            {
            return (Object*)new UXSplitView();
            }
        return (Object*)0;
        }

    // ---- attributes: the settings a control has no OBJECT field for -----------------------------
    // Apply a control's attributes to the view made for it: the theme's own values where it varies
    // them, else the shared ones.  Lists are written "One|Two|Three".
    static void applyAttrs(UXView* v, UXRscDoc* doc, i32 formId, i32 logicalId, i32 theme)
        {
        if (v == (UXView*)0 || doc == (UXRscDoc*)0 || logicalId == (i32)0 || doc.attrs.count() == (u32)0)
            {
            return;
            }
        UXSlider* sl = (UXSlider* ?)(Object*)v;
        if (sl != (UXSlider*)0)
            {
            sl.setRange(UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"min", (i32)0), UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"max", (i32)100));
            sl.setValue(UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"value", (i32)0));
            return;
            }
        UXStepper* st = (UXStepper* ?)(Object*)v;
        if (st != (UXStepper*)0)
            {
            st.setRange(UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"min", (i32)0), UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"max", (i32)100));
            st.setStep(UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"step", (i32)1));
            st.setValue(UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"value", (i32)0));
            return;
            }
        UXProgressBar* pb = (UXProgressBar* ?)(Object*)v;
        if (pb != (UXProgressBar*)0)
            {
            Progress* pr = new Progress();
            pr.setTotalUnitCount((i64)UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"total", (i32)100));
            pr.setCompletedUnitCount((i64)UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"completed", (i32)0));
            pb.setProgress(pr);
            return;
            }
        UXSegmentedControl* sg = (UXSegmentedControl* ?)(Object*)v;
        if (sg != (UXSegmentedControl*)0)
            {
            u8* segs = doc.attrIn(formId, logicalId, theme, (u8*)"segments");
            i32 n = UXRsc.eachPart(segs, (pointer)sg, (i32)0);
            if (n > (i32)0)
                {
                sg.applyNativeSelection(UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"selected", (i32)0));
                }
            return;
            }
        UXComboBox* cb = (UXComboBox* ?)(Object*)v;
        if (cb != (UXComboBox*)0)
            {
            UXRsc.eachPart(doc.attrIn(formId, logicalId, theme, (u8*)"items"), (pointer)cb, (i32)1);
            u8* t = doc.attrIn(formId, logicalId, theme, (u8*)"text");
            if (t != (u8*)0)
                {
                cb.setText(t);
                }
            return;
            }
        UXTextView* tv = (UXTextView* ?)(Object*)v;
        if (tv != (UXTextView*)0)
            {
            i32 fs = UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"fontSize", (i32)0);
            if (fs > (i32)0)
                {
                tv.setDefaultFontSize(fs);
                }
            tv.setMonospace(UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"monospace", (i32)0) != (i32)0);
            u8* t = doc.attrIn(formId, logicalId, theme, (u8*)"text");
            if (t != (u8*)0)
                {
                tv.setText(String.withCString(t));
                }
            return;
            }
        UXDatePicker* dp = (UXDatePicker* ?)(Object*)v;
        if (dp != (UXDatePicker*)0)
            {
            UXDate* dd = UXRsc.dateFrom(doc.attrIn(formId, logicalId, theme, (u8*)"date"));
            if (dd != (UXDate*)0)
                {
                dp.setDate(dd);
                }
            return;
            }
        UXBreadcrumb* bc = (UXBreadcrumb* ?)(Object*)v;
        if (bc != (UXBreadcrumb*)0)
            {
            u8* sep = doc.attrIn(formId, logicalId, theme, (u8*)"separator");
            if (sep != (u8*)0 && sep[0] != (u8)0)
                {
                bc.setSeparator(sep);
                }
            UXRsc.eachPart(doc.attrIn(formId, logicalId, theme, (u8*)"segments"), (pointer)bc, (i32)2);
            return;
            }
        UXTableView* tbl = (UXTableView* ?)(Object*)v; // an outline is one, so its columns come too
        if (tbl != (UXTableView*)0)
            {
            UXRsc.eachColumn(doc.attrIn(formId, logicalId, theme, (u8*)"columns"), tbl);
            return;
            }
        UXCollectionView* cv = (UXCollectionView* ?)(Object*)v;
        if (cv != (UXCollectionView*)0)
            {
            i32 isz = UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"itemSize", (i32)0);
            if (isz > (i32)0)
                {
                cv.setItemSize((i16)isz, (i16)isz);
                }
            i32 gap = UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"spacing", (i32)-1);
            if (gap >= (i32)0)
                {
                cv.setSpacing((i16)gap, (i16)gap);
                }
            UXRsc.eachPart(doc.attrIn(formId, logicalId, theme, (u8*)"items"), (pointer)cv, (i32)3);
            return;
            }
        UXScrollView* sc = (UXScrollView* ?)(Object*)v;
        if (sc != (UXScrollView*)0)
            {
            i32 lh = UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"lineHeight", (i32)0);
            if (lh > (i32)0)
                {
                sc.setLineHeight((i16)lh);
                }
            return;
            }
        UXSplitView* sp = (UXSplitView* ?)(Object*)v;
        if (sp != (UXSplitView*)0)
            {
            sp.setVertical(UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"vertical", (i32)0) != (i32)0);
            i32 dp = UXRsc.attrInt(doc, formId, logicalId, theme, (u8*)"divider", (i32)0);
            if (dp > (i32)0)
                {
                sp.setDividerPos((i16)dp);
                }
            }
        }
    // ---- autoresizing: how a view follows its container when that is resized ---------------------
    // The layout's own mask (UXRscDoc.maskFrom has the format).
    static i32 autoresizeOf(UXRscDoc* doc, i32 formId, i32 logicalId, i32 theme)
        {
        if (doc == (UXRscDoc*)0 || logicalId == (i32)0)
            {
            return (i32)0;
            }
        return UXRscDoc.maskFrom(doc.attrIn(formId, logicalId, theme, (u8*)"autoresize"));
        }

    static i32 attrInt(UXRscDoc* doc, i32 formId, i32 logicalId, i32 theme, u8* key, i32 dflt)
        {
        u8* v = doc.attrIn(formId, logicalId, theme, key);
        if (v == (u8*)0 || v[0] == (u8)0)
            {
            return dflt;
            }
        i32 n = (i32)0;
        i32 i = (i32)0;
        bool neg = v[0] == (u8)'-';
        if (neg)
            {
            i = (i32)1;
            }
        while (v[i] >= (u8)'0' && v[i] <= (u8)'9')
            {
            n = n * (i32)10 + (i32)(v[i] - (u8)'0');
            i = i + (i32)1;
            }
        return neg ? (i32)0 - n : n;
        }
    // A leading run of digits, or dflt when there is none (a column width, say).
    static i32 intFrom(u8* s, i32 dflt)
        {
        if (s == (u8*)0)
            {
            return dflt;
            }
        i32 n = (i32)0;
        i32 i = (i32)0;
        while (s[i] >= (u8)'0' && s[i] <= (u8)'9')
            {
            n = n * (i32)10 + (i32)(s[i] - (u8)'0');
            i = i + (i32)1;
            }
        return i > (i32)0 ? n : dflt;
        }
    // Add each part of "A|B|C" to a segmented control (to = 0) or a combo box (to = 1); how many.
    // A date written YYYY-MM-DD, or 0 (none, or not a date: the picker keeps today).
    static UXDate* dateFrom(u8* s)
        {
        if (s == (u8*)0)
            {
            return (UXDate*)0;
            }
        i32 f[3];
        i32 k = (i32)0;
        i32 i = (i32)0;
        f[0] = (i32)0;
        f[1] = (i32)0;
        f[2] = (i32)0;
        bool any = false;
        while (s[i] != (u8)0 && k < (i32)3)
            {
            if (s[i] >= (u8)'0' && s[i] <= (u8)'9')
                {
                f[k] = f[k] * (i32)10 + (i32)(s[i] - (u8)'0');
                any = true;
                }
            else if (s[i] == (u8)'-')
                {
                k = k + (i32)1;
                }
            else
                {
                return (UXDate*)0;
                }
            i = i + (i32)1;
            }
        if (!any || k != (i32)2 || f[1] < (i32)1 || f[1] > (i32)12 || f[2] < (i32)1 || f[2] > (i32)31)
            {
            return (UXDate*)0;
            }
        return UXDate.make(f[0], f[1], f[2]);
        }
    // Add each part of "A|B|C" to a list control: 0 a segmented control's segments, 1 a combo box's
    // items, 2 a breadcrumb's segments, 3 a collection view's items.  The count.
    static i32 eachPart(u8* list, pointer target, i32 to)
        {
        if (list == (u8*)0)
            {
            return (i32)0;
            }
        i32 n = (i32)0;
        i32 start = (i32)0;
        i32 i = (i32)0;
        while (true)
            {
            if (list[i] == (u8)'|' || list[i] == (u8)0)
                {
                u8* part = new u8[(u32)(i - start + (i32)1)];
                for (i32 k = start; k < i; k = k + (i32)1)
                    {
                    part[k - start] = list[k];
                    }
                part[i - start] = (u8)0;
                if (to == (i32)0)
                    { ((UXSegmentedControl*)(Object*)target).addSegment(part, n);
                    }
                else if (to == (i32)1)
                    { ((UXComboBox*)(Object*)target).addItem(part);
                    }
                else if (to == (i32)2)
                    { ((UXBreadcrumb*)(Object*)target).addSegment(part, n);
                    }
                else
                    { ((UXCollectionView*)(Object*)target).addItem((Object*)0, part);
                    }
                n = n + (i32)1;
                if (list[i] == (u8)0)
                    {
                    break;
                    }
                start = i + (i32)1;
                }
            i = i + (i32)1;
            }
        return n;
        }
    // Add each column of "Title:Width|Title:Width" to a table (an outline is one, so its columns
    // come too).  A part with no ":width" gets the default.  The count.
    static i32 eachColumn(u8* list, UXTableView* t)
        {
        if (list == (u8*)0 || t == (UXTableView*)0)
            {
            return (i32)0;
            }
        i32 n = (i32)0;
        i32 start = (i32)0;
        i32 i = (i32)0;
        while (true)
            {
            if (list[i] == (u8)'|' || list[i] == (u8)0)
                {
                u8* part = new u8[(u32)(i - start + (i32)1)];
                i32 colon = (i32)-1;
                for (i32 k = start; k < i; k = k + (i32)1)
                    {
                    part[k - start] = list[k];
                    if (list[k] == (u8)':' && colon < (i32)0)
                        {
                        colon = k - start;
                        }
                    }
                part[i - start] = (u8)0;
                i16 w = (i16)80;
                if (colon >= (i32)0)
                    {
                    part[colon] = (u8)0;
                    w = (i16)UXRsc.intFrom(part + colon + (i32)1, (i32)80);
                    }
                t.addColumn(part, w);
                n = n + (i32)1;
                if (list[i] == (u8)0)
                    {
                    break;
                    }
                start = i + (i32)1;
                }
            i = i + (i32)1;
            }
        return n;
        }

    // ---- loading -------------------------------------------------------------------------------
    // From .rsc bytes, for this device's theme, into `into` (a window's content view, say): the
    // form's root becomes a subview at the container's origin.  With no container the form gets a
    // view tree of its own (ni.viewTree).  0 if the bytes are not a resource or there is no such
    // form.
    static UXRscInstance* load(u8* bytes, i32 n, i32 formId, UXDesignable* owner, UXView* into)
        {
        UXRscDoc* doc = UXRscReader.read(bytes, n);
        return doc != (UXRscDoc*)0 ? UXRsc.loadDoc(doc, formId, owner, into) : (UXRscInstance*)0;
        }
    static UXRscInstance* loadDoc(UXRscDoc* doc, i32 formId, UXDesignable* owner, UXView* into)
        {
        i32 klass = (i32)UX_FORM_DESKTOP;
        i32 orient = (i32)UX_ORIENT_NONE;
        if (gDriver != (UXViewDriver*)0)
            {
            klass = gDriver.formFactorClass();
            orient = gDriver.orientation();
            }
        return UXRsc.loadDocAs(doc, formId, klass, orient, owner, into);
        }
    // For a given theme: what a test, or the designer's preview, asks for.
    static UXRscInstance* loadDocAs(UXRscDoc* doc, i32 formId, i32 klass, i32 orient, UXDesignable* owner,
                                    UXView* into)
        {
        i32 gotClass = (i32)0;
        i32 gotOrient = (i32)0;
        UXRscTree* t = UXRsc.selectTree(doc, formId, klass, orient, &gotClass, &gotOrient);
        if (t == (UXRscTree*)0 || t.root == (UXRscObject*)0)
            {
            return (UXRscInstance*)0;
            }
        UXRscInstance* ni = new UXRscInstance();
        ni.tree = t;
        ni.formId = formId;
        ni.klass = gotClass;
        ni.orient = gotOrient;
        i32 treeIndex = doc.indexOfTree(t);

        // views: the root box is the form's own view; its children are built into it
        // (a plain view unless its class is overridden: the window draws the form's background)
        u8* rootCls = UXRsc.classFor(doc, formId, treeIndex, t.root, (i32)0);
        UXView* rv = (UXView*)0;
        if (rootCls != (u8*)0)
            { rv = (UXView* ?)UXRsc.make(rootCls);
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
        rv.setAutoresizeMask(UXRsc.autoresizeOf(doc, formId, t.root.logicalId, (i32)UXRscConnection.themeBit(gotClass, gotOrient)));
        ni.root = rv;
        ni.objs.add(t.root);
        ni.views.add(rv);
        Array<UXRscObject>* order = t.allObjects(); // pre-order: the index a space-0 Ref names
        for (i32 i = (i32)0; i < t.root.childCount(); i = i + (i32)1)
            {
            UXRsc.build(doc, ni, order, treeIndex, t.root.childAt(i), rv, (i32)0, (i32)0);
            }

        // top-level objects: the document's, made on every load
        for (u32 i = (u32)0; i < doc.topObjects.count(); i = i + (u32)1)
            {
            UXRscTopObject* rec = (UXRscTopObject* ?)doc.topObjects.get(i);
            Object* o = UXRsc.make(rec.cls);
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
            if (!UXRsc.concerns(doc, c, formId))
                {
                continue;
                }
            if (!c.inScope(gotClass, gotOrient))
                {
                ni.outOfScope = ni.outOfScope + (i32)1;
                continue;
                }
            Object* src = UXRsc.resolve(ni, order, treeIndex, c.src, owner);
            Object* dst = UXRsc.resolve(ni, order, treeIndex, c.dst, owner);
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

        // awakeFromRsc: the objects made here, then File's Owner
        for (u32 i = (u32)0; i < ni.tops.count(); i = i + (u32)1)
            {
            UXRsc.awake((Object* ?)ni.tops.get(i));
            }
        for (u32 i = (u32)0; i < ni.views.count(); i = i + (u32)1)
            {
            UXRsc.awake((Object* ?)ni.views.get(i));
            }
        UXRsc.awake((Object*)owner);
        return ni;
        }

    static void awake(Object* o)
        {
        UXRscAwaking* a = (UXRscAwaking* ?)o;
        if (a != (UXRscAwaking*)0)
            {
            a.awakeFromRsc();
            }
        }

    static void build(UXRscDoc* doc, UXRscInstance* ni, Array<UXRscObject>* order, i32 treeIndex,
                      UXRscObject* o, UXView* parent, i32 dx, i32 dy)
        {
        UXView* v = UXRsc.viewFor(o, UXRsc.classFor(doc, ni.formId, treeIndex, o, UXRsc.indexIn(order, o)));
        parent.addSubview(v, UXGeom.make((i16)(o.x - dx), (i16)(o.y - dy), (i16)o.w, (i16)o.h));
        i32 bit = (i32)UXRscConnection.themeBit(ni.klass, ni.orient);
        UXRsc.applyState(v, o);
        UXRsc.applyAttrs(v, doc, ni.formId, o.logicalId, bit);
        v.setAutoresizeMask(UXRsc.autoresizeOf(doc, ni.formId, o.logicalId, bit));
        ni.objs.add(o);
        ni.views.add(v);
        i32 extent = (i32)0;
        for (i32 i = (i32)0; i < o.childCount(); i = i + (i32)1)
            {
            UXRscObject* c = o.childAt(i);
            i32 cdx = (i32)0;
            i32 cdy = (i32)0;
            UXView* inner = UXRsc.childParent(v, doc, ni.formId, bit, c, &cdx, &cdy);
            UXRsc.build(doc, ni, order, treeIndex, c, inner, cdx, cdy);
            i32 bottom = (i32)c.y + (i32)c.h;
            if (bottom > extent)
                {
                extent = bottom;
                }
            }
        UXRsc.containerFilled(v, extent);
        }

    // Where a container's designed children go.  A scroll view keeps them all in its document; a
    // split view sends each to the pane its `slot` attribute names; every other view holds them itself.
    // A child's frame is relative to the container, so when it goes into a sub-view whose origin is not
    // the container's, (dx, dy) is that origin, to subtract.
    static UXView* childParent(UXView* v, UXRscDoc* doc, i32 formId, i32 theme, UXRscObject* child,
                               i32* dx, i32* dy)
        {
        dx[0] = (i32)0;
        dy[0] = (i32)0;
        UXScrollView* sv = (UXScrollView* ?)(Object*)v;
        if (sv != (UXScrollView*)0)
            {
            UXView* d = sv.document();
            if (d != (UXView*)0)
                {
                return d;
                }
            }
        UXSplitView* sp = (UXSplitView* ?)(Object*)v;
        if (sp != (UXSplitView*)0)
            {
            i32 slot = (i32)0;
            if (doc != (UXRscDoc*)0)
                {
                slot = UXRsc.attrInt(doc, formId, child.logicalId, theme, (u8*)"slot", (i32)0);
                }
            UXView* p = slot == (i32)1 ? sp.secondPane() : sp.firstPane();
            if (p != (UXView*)0)
                {
                dx[0] = slot == (i32)1 ? (i32)sp.dividerPosition() : (i32)0;
                return p;
                }
            }
        return v;
        }
    // After a container's children are in, tell it how much content it has; a scroll view sizes its
    // bar from the extent.
    static void containerFilled(UXView* v, i32 extent)
        {
        UXScrollView* sv = (UXScrollView* ?)(Object*)v;
        if (sv != (UXScrollView*)0)
            {
            sv.setDocumentHeight(extent);
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
            i32 want = UXRscV2.chain(klass, step);
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
        return UXRsc.refConcerns(doc, c.src, formId) && UXRsc.refConcerns(doc, c.dst, formId);
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

    static Object* resolve(UXRscInstance* ni, Array<UXRscObject>* order, i32 treeIndex, UXRscRef* r, UXDesignable* owner)
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
            UXView* cv = (UXView* ?)UXRsc.make(cls);
            if (cv != (UXView*)0)
                {
                return cv;
                }
            }
        i32 t = o.type;
        if (t == (i32)UXR_T_BUTTON)
            {
            UXButton* b = new UXButton();
            b.setTitle(UXRsc.textOf(o));
            return (UXView*)b;
            }
        if (t == (i32)UXR_T_CHECKBOX)
            {
            UXCheckbox* c = new UXCheckbox();
            c.setTitle(UXRsc.textOf(o));
            c.setChecked((o.state & (i32)UXR_S_CHECKED) != (i32)0);
            return (UXView*)c;
            }
        if (t == (i32)UXR_T_RADIO)
            {
            UXRadioButton* r = new UXRadioButton();
            r.setTitle(UXRsc.textOf(o));
            r.setSelected((o.state & (i32)UXR_S_SELECTED) != (i32)0);
            return (UXView*)r;
            }
        if (t == (i32)UXR_T_STRING || t == (i32)UXR_T_TEXT || t == (i32)UXR_T_TITLE)
            {
            UXLabel* l = new UXLabel();
            l.setTitle(UXRsc.textOf(o));
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
            p.addItem(UXRsc.textOf(o), (i32)0);
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
        unknown.setTitle(cls != (u8*)0 && cls[0] != (u8)0 ? cls : UXRsc.typeName(o.type));
        return (UXView*)unknown;
        }

    // The UXKit class viewFor makes for a GEM type: what a control is when nothing overrides it.
    static u8* defaultClassFor(i32 t)
        {
        if (t == (i32)UXR_T_BUTTON)
            {
            return (u8*)"UXButton";
            }
        if (t == (i32)UXR_T_CHECKBOX)
            {
            return (u8*)"UXCheckbox";
            }
        if (t == (i32)UXR_T_RADIO)
            {
            return (u8*)"UXRadioButton";
            }
        if (t == (i32)UXR_T_STRING || t == (i32)UXR_T_TEXT || t == (i32)UXR_T_TITLE)
            {
            return (u8*)"UXLabel";
            }
        if (t == (i32)UXR_T_FIELD || t == (i32)UXR_T_FTEXT || t == (i32)UXR_T_BOXTEXT || t == (i32)UXR_T_FBOXTEXT)
            {
            return (u8*)"UXTextField";
            }
        if (t == (i32)UXR_T_POPUP)
            {
            return (u8*)"UXPopUpButton";
            }
        if (t == (i32)UXR_T_BOX || t == (i32)UXR_T_BOXCHAR)
            {
            return (u8*)"UXGroupBox";
            }
        return (u8*)"UXView";
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
        u8* t = UXRsc.textOf(o);
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
