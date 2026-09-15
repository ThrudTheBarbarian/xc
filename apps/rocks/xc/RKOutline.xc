// RKOutline.xc — the document's structure, for the left-hand pane.
//
// The canvas shows ONE form.  A .rsc holds several — the XT GEM desktop has
// four — and without this pane there is no way to know the other three exist,
// let alone reach them.  So the outline is the document: trees at the top
// level, each object's nesting beneath, which is also the tree the designer
// re-parents things in.
//
// The rows are a MATERIALIZED model rather than the RKObject graph itself.
// UXOutlineDataSource hands items back as `Object*`, and answering
// "is this a tree or an object?" on the way back in would need runtime type
// information that would have to be faked with a tag field anyway.  One node
// type with an optional payload is simpler and lets a row carry a label the
// model has no place for — "New dialog (11 objects)" is a view concern, not a
// resource one.
#import "Array.xc"
#import "UXOutlineView.xc"
#import "RKModel.xc"
#import "RKCanvas.xc"

class RKOutlineNode : Object
    {
    u8* label;
    RKObject* obj; // the object this row stands for, or 0 for a tree row
    i32 treeIndex; // which tree; -1 when the row is inside one
    Array<RKOutlineNode>* kids;
    void init(void)
        {
        label = (u8*)"";
        obj = (RKObject*)0;
        treeIndex = (i32)-1;
        kids = new Array();
        }
    }

    class RKOutline : Object<UXOutlineDataSource>
    {
    Array<RKOutlineNode>* roots;

    void init(void)
        {
        roots = new Array();
        }

    // Build the whole outline from a resource.  Cheap enough to redo on any
    // structural edit, which keeps it honest: there is no incremental update
    // path to fall out of step with the model.
    void build(RKResource* r)
        {
        roots = new Array();
        if (r == (RKResource*)0)
            {
            return;
            }
        for (i32 t = (i32)0; t < r.treeCount(); t = t + (i32)1)
            {
            RKTree* tr = r.treeAt(t);
            RKOutlineNode* n = new RKOutlineNode();
            n.treeIndex = t;
            n.label = RKOutline.treeLabel(tr, t);
            if (tr.root != (RKObject*)0)
                {
                // The root box IS the form, so its children hang directly off
                // the tree row rather than under a redundant "box" row — the
                // same choice the canvas makes about not realizing the root.
                for (i32 i = (i32)0; i < tr.root.childCount(); i = i + (i32)1)
                    {
                    n.kids.add(RKOutline.nodeFor(tr.root.childAt(i)));
                    }
                }
            roots.add(n);
            }
        }

    static RKOutlineNode* nodeFor(RKObject* o)
        {
        RKOutlineNode* n = new RKOutlineNode();
        n.obj = o;
        n.label = RKOutline.objectLabel(o);
        for (i32 i = (i32)0; i < o.childCount(); i = i + (i32)1)
            {
            n.kids.add(RKOutline.nodeFor(o.childAt(i)));
            }
        return n;
        }

    // "dialog 0" / "menu 1" — a tree's name is usually empty in a real file
    // (the names live in the app's header, not the resource), so the kind and
    // index are what actually identify it.
    static u8* treeLabel(RKTree* t, i32 i)
        {
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

    // The object's text if it has any, else its type — so a row reads
    // "OK" rather than "button", but an untitled box still says what it is.
    static u8* objectLabel(RKObject* o)
        {
        u8* t = RKCanvas.textOf(o);
        if (t != (u8*)0 && t[0] != (u8)0)
            {
            return t;
            }
        return RKCanvas.typeName(o.type);
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
