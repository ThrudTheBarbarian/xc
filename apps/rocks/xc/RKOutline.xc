// RKOutline.xc — the document's structure, for the left-hand pane.
//
// The canvas shows ONE form.  A .rsc holds several — the XT GEM desktop has
// four — and without this pane there is no way to know the other three exist,
// let alone reach them.  So the outline is the document, laid out as Interface
// Builder's: File's Owner and First Responder, the objects the document makes,
// then each form with its controls nested beneath, which is also the tree the
// designer re-parents things in.
//
// The rows are a MATERIALIZED model rather than the UXRscObject graph itself.
// UXOutlineDataSource hands items back as `Object*`, and answering
// "is this a tree or an object?" on the way back in would need runtime type
// information that would have to be faked with a tag field anyway.  One node
// type with an optional payload is simpler and lets a row carry a label the
// model has no place for — "New dialog (11 objects)" is a view concern, not a
// resource one.
#import "Array.xc"
#import "UXOutlineView.xc"
#import "UXRscModel.xc"
#import "RKCanvas.xc"

// The kinds of row, in the order Interface Builder lists them: the placeholders, the objects the
// document makes, then the forms and their views.
#define RKON_OWNER 1  // File's Owner
#define RKON_FIRSTR 2 // First Responder
#define RKON_OBJECT 3 // a top-level object (topId)
#define RKON_FORM 4   // a form, showing the layout being viewed (treeIndex)
#define RKON_VIEW 5   // a control in that layout (obj)

class RKOutlineNode : Object
    {
    u8* label;
    i32 kind;         // RKON_*
    UXRscObject* obj; // RKON_VIEW: the object this row stands for
    i32 treeIndex;    // RKON_FORM: the tree it shows; -1 otherwise
    i32 topId;        // RKON_OBJECT: the top-level object's id
    Array<RKOutlineNode>* kids;
    void init(void)
        {
        label = (u8*)"";
        kind = (i32)RKON_VIEW;
        obj = (UXRscObject*)0;
        treeIndex = (i32)-1;
        topId = (i32)0;
        kids = new Array();
        }
    static RKOutlineNode* make(i32 kind, u8* label)
        {
        RKOutlineNode* n = new RKOutlineNode();
        n.kind = kind;
        n.label = label;
        return n;
        }
    }

    class RKOutline : Object<UXOutlineDataSource>
    {
    Array<RKOutlineNode>* roots;
    Array<RKOutlineNode>* dragged; // rows dragged out: a drag carries its row's place here

    void init(void)
        {
        roots = new Array();
        dragged = new Array();
        }

    // A row that can be one end of a connection drags out as "rk-end:<n>", n its place in
    // `dragged`; a form's row does not drag.
    u8* dragTextForItem(UXOutlineView* o, Object* item)
        {
        RKOutlineNode* n = (RKOutlineNode* ?)item;
        if (n == (RKOutlineNode*)0 || n.kind == (i32)RKON_FORM)
            {
            return (u8*)0;
            }
        i32 at = (i32)dragged.count();
        dragged.add(n);
        u8* t = new u8[(u32)20];
        u8* pre = (u8*)"rk-end:";
        for (i32 i = (i32)0; i < (i32)7; i = i + (i32)1)
            {
            t[i] = pre[i];
            }
        i32 digits = (i32)1;
        for (i32 v = at; v >= (i32)10; v = v / (i32)10)
            {
            digits = digits + (i32)1;
            }
        for (i32 i = digits - (i32)1; i >= (i32)0; i = i - (i32)1)
            {
            t[(i32)7 + i] = (u8)((i32)'0' + at % (i32)10);
            at = at / (i32)10;
            }
        t[(i32)7 + digits] = (u8)0;
        return t;
        }
    // The row a drag's text stands for, or 0 if it is not one of ours.
    RKOutlineNode* draggedRow(u8* text)
        {
        u8* pre = (u8*)"rk-end:";
        for (i32 i = (i32)0; i < (i32)7; i = i + (i32)1)
            {
            if (text[i] != pre[i])
                {
                return (RKOutlineNode*)0;
                }
            }
        i32 v = (i32)0;
        for (i32 i = (i32)7; text[i] >= (u8)'0' && text[i] <= (u8)'9'; i = i + (i32)1)
            {
            v = v * (i32)10 + (i32)(text[i] - (u8)'0');
            }
        if (v >= (i32)dragged.count())
            {
            return (RKOutlineNode*)0;
            }
        return (RKOutlineNode* ?)dragged.get((u32)v);
        }


    // Rebuild from the document, for the layout theme being viewed: each form is one row, showing
    // that theme's layout if it has one and otherwise its first.
    void build(UXRscDoc* r, i32 klass, i32 orient)
        {
        roots = new Array();
        dragged = new Array(); // the rows it stood for are gone
        if (r == (UXRscDoc*)0)
            {
            return;
            }
        roots.add(RKOutlineNode.make((i32)RKON_OWNER, (u8*)"File's Owner"));
        roots.add(RKOutlineNode.make((i32)RKON_FIRSTR, (u8*)"First Responder"));
        for (u32 i = (u32)0; i < r.topObjects.count(); i = i + (u32)1)
            {
            UXRscTopObject* to = (UXRscTopObject* ?)r.topObjects.get(i);
            RKOutlineNode* n = RKOutlineNode.make((i32)RKON_OBJECT, RKOutline.topLabel(to));
            n.topId = to.id;
            roots.add(n);
            }
        for (i32 t = (i32)0; t < r.treeCount(); t = t + (i32)1)
            {
            UXRscTree* tr = r.treeAt(t);
            UXRscForm* f = r.formOf(tr);
            i32 shown = t;
            if (f != (UXRscForm*)0)
                {
                // a form is listed once, where its first layout is
                if (r.indexOfTree(f.variantAt((i32)0).tree) != t)
                    {
                    continue;
                    }
                UXRscVariant* v = f.find(klass, orient);
                if (v == (UXRscVariant*)0 && orient != (i32)UXR_V_ORIENT_NONE)
                    {
                    v = f.find(klass, (i32)UXR_V_ORIENT_NONE);
                    }
                if (v != (UXRscVariant*)0)
                    {
                    shown = r.indexOfTree(v.tree);
                    }
                }
            UXRscTree* st = r.treeAt(shown);
            RKOutlineNode* n = RKOutlineNode.make((i32)RKON_FORM, RKOutline.treeLabel(f != (UXRscForm*)0 ? tr : st, t));
            n.treeIndex = shown;
            if (st.root != (UXRscObject*)0)
                {
                for (i32 i = (i32)0; i < st.root.childCount(); i = i + (i32)1)
                    {
                    n.kids.add(RKOutline.nodeFor(r, st, st.root.childAt(i)));
                    }
                }
            roots.add(n);
            }
        }
    // The row for a form's tree (any of its layouts' trees), or 0.
    RKOutlineNode* formRow(i32 treeIndex)
        {
        for (u32 i = (u32)0; i < roots.count(); i = i + (u32)1)
            {
            RKOutlineNode* n = (RKOutlineNode* ?)roots.get(i);
            if (n.kind == (i32)RKON_FORM && n.treeIndex == treeIndex)
                {
                return n;
                }
            }
        return (RKOutlineNode*)0;
        }

    static RKOutlineNode* nodeFor(UXRscDoc* r, UXRscTree* tr, UXRscObject* o)
        {
        RKOutlineNode* n = RKOutlineNode.make((i32)RKON_VIEW, RKOutline.objectLabel(r, tr, o));
        n.obj = o;
        for (i32 i = (i32)0; i < o.childCount(); i = i + (i32)1)
            {
            n.kids.add(RKOutline.nodeFor(r, tr, o.childAt(i)));
            }
        return n;
        }

    // An object's row: its label if it has one, else its class.
    static u8* topLabel(UXRscTopObject* to)
        {
        if (to.label != (u8*)0 && to.label[0] != (u8)0)
            {
            return to.label;
            }
        return to.cls != (u8*)0 && to.cls[0] != (u8)0 ? to.cls : (u8*)"Object";
        }

    // A form's row: its name, else "dialog 3".
    static u8* treeLabel(UXRscTree* t, i32 i)
        {
        if (t.name != (u8*)0 && t.name[0] != (u8)0)
            {
            return t.name;
            }
        u8* kind = t.isMenu() ? (u8*)"menu" : (u8*)"dialog";
        u8* buf = new u8[(u32)32];
        i32 n = (i32)0;
        while (kind[n] != (u8)0)
            {
            buf[n] = kind[n];
            n = n + (i32)1;
            }
        buf[n] = (u8)32;
        n = n + (i32)1;
        if (i >= (i32)10)
            {
            buf[n] = (u8)((i32)48 + i / (i32)10);
            n = n + (i32)1;
            }
        buf[n] = (u8)((i32)48 + i % (i32)10);
        n = n + (i32)1;
        buf[n] = (u8)0;
        return buf;
        }

    // The object's name if it has one, its text if it has any, else its type -- so a row reads
    // "playButton" or "OK" rather than "button", and an untitled box still says what it is.
    static u8* objectLabel(UXRscDoc* r, UXRscTree* tr, UXRscObject* o)
        {
        if (o.name != (u8*)0 && o.name[0] != (u8)0)
            {
            return o.name;
            }
        u8* t = UXRsc.textOf(o);
        if (t != (u8*)0 && t[0] != (u8)0)
            {
            return t;
            }
        // A UXKit view carries no text: show its class (the G_USERDEF's override), not "userdef".
        if (r != (UXRscDoc*)0 && tr != (UXRscTree*)0)
            {
            u8* cls = r.classOf(tr, o);
            if (cls != (u8*)0 && cls[0] != (u8)0)
                {
                return cls;
                }
            }
        return UXRsc.typeName(o.type);
        }

    // ---- UXOutlineDataSource ----------------------------------------------
    // A null item means the root level, which is the list of trees.
    i32 numberOfChildren(UXOutlineView* o, Object* item)
        {
        if (item == (Object*)0)
            {
            return (i32)roots.count();
            }
        return (i32)((RKOutlineNode* ?)item).kids.count();
        }
    Object* childOfItem(UXOutlineView* o, Object* item, i32 i)
        {
        Array<RKOutlineNode>* list = item == (Object*)0
            ? roots : ((RKOutlineNode* ?)item).kids;
        if (i < (i32)0 || i >= (i32)list.count())
            {
            return (Object*)0;
            }
        return (Object*)list.get((u16)i);
        }
    bool isExpandable(UXOutlineView* o, Object* item)
        {
        if (item == (Object*)0)
            {
            return true;
            }
        return ((RKOutlineNode* ?)item).kids.count() > (u16)0;
        }
    u8* valueForItem(UXOutlineView* o, Object* item, i32 col)
        {
        if (item == (Object*)0)
            {
            return (u8*)"";
            }
        return ((RKOutlineNode* ?)item).label;
        }
    }
