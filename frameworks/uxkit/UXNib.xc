// UXNib.xc — a .rsc IS the nib, and it is LIVE.
//
// There is no inflation step.  A GEM resource already contains an OBJECT tree, and
// an UXView is backed by an OBJECT — so loading a nib means loading the tree and
// binding a view object onto each entry.  Nothing is copied, nothing is rebuilt,
// and the AES walks the resource's own array.
//
// Which means: Rocks — the resource editor — is the Interface Builder for Xtg, and
// a dialog designed there becomes a live view hierarchy here with no conversion.
//
//   Rocks (macOS) --writes--> app.rsc --rscload_file--> OBJECT[] --UXNib--> UXViewTree
//
// Views are chosen by ob_type.  The resource supplies the type, frame, flags and
// state; Xtg supplies the behaviour.

#import "UXGem.h.xc"
#import "UXViewTree.xc"
#import "UXView.xc"
#import "UXControl.xc"
#import "UXDesignable.xc"
#import "Array.xc"

pointer rscload_file(u8* path, pointer err);
pointer rscload_mem(u8* data, u32 len, pointer err);
pointer rscload_tree(pointer doc, i32 index);
i32 rscload_ntrees(pointer doc);
void rscload_free(pointer doc);

// The UXNB nib extension (libGEM rscload).  Refs come out as (space, a, b) per UXKit-NIB.md.
i32 rscload_nib_present(pointer doc);
i32 rscload_nib_nclassov(pointer doc);
i32 rscload_nib_ntopobj(pointer doc);
i32 rscload_nib_nconn(pointer doc);
u8* rscload_nib_classov(pointer doc, i32 i, i32* space, i32* a, i32* b);
u8* rscload_nib_topobj(pointer doc, i32 i, i32* id);
u8* rscload_nib_conn(pointer doc, i32 i, i32* kind, i32* ss, i32* sa, i32* sb, i32* ds, i32* da, i32* db);

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

class UXNib
    {
    // Load one tree from a .rsc and bind a view onto every object in it.
    // Returns nil if the file will not load.
    static UXViewTree* load(u8* path, i32 treeIndex)
        {
        pointer err = (pointer)0;
        pointer doc = rscload_file(path, (pointer)&err);
        if (doc == (pointer)0)
            {
            return (UXViewTree*)0;
            }
        if (treeIndex >= rscload_ntrees(doc))
            {
            rscload_free(doc);
            return (UXViewTree*)0;
            }

        OBJECT* t = (OBJECT*)rscload_tree(doc, treeIndex);
        if (t == (OBJECT*)0)
            {
            rscload_free(doc);
            return (UXViewTree*)0;
            }

        // How many objects?  The AES's own terminator says so.
        u16 n = (u16)0;
        while (n < (u16)2000)
            {
            u16 f = t[n].ob_flags;
            n = n + (u16)1;
            if ((f & (u16)OF_LASTOB) != (u16)0)
                {
                break;
                }
            }

        UXViewTree* vt = new UXViewTree();
        vt.adopt((pointer)t, n); // the nib's OBJECT[] -> the tree's opaque structure

        // Bind a view per object.  The resource already said what each one IS.
        for (u16 i = (u16)0; i < n; i++)
            {
            UXView* v = UXNib.viewForType((u16)(t[i].ob_type & (u16)$00FF));
            v.adoptObject(vt, i);
            }
        return vt;
        }

    // The factory.  No reflection, no registry — a switch, which is all it needs
    // to be, and the compiler checks every arm.
    static UXView* viewForType(u16 gtype)
        {
        if (gtype == (u16)G_BUTTON)
            {
            UXButton* b = new UXButton();
            return b;
            }
        // Every other type is drawn by GEM exactly as the resource describes it —
        // box, string, text, icon, checkbox, radio, popup, field.  A plain UXView
        // gives it identity, hit-testing and a place in the responder chain
        // without us drawing a single pixel.
        UXView* v = new UXView();
        return v;
        }

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
    // The class named for a G_USERDEF view at (tree, obj) by the UXNB extension, or null.
    static u8* classOverride(pointer doc, i32 ncl, i32 tree, i32 obj)
        {
        for (i32 k = (i32)0; k < ncl; k = k + (i32)1)
            {
            i32 sp = (i32)0;
            i32 a = (i32)0;
            i32 b = (i32)0;
            u8* cls = rscload_nib_classov(doc, k, &sp, &a, &b);
            // space 0 = VIEW
            if (sp == (i32)0 && a == tree && b == obj)
                {
                return cls;
                }
            }
        return (u8*)0;
        }

    // Load a tree bound to `owner` (File's Owner, a UXDesignable), consuming the UXNB extension:
    // custom view classes, top-level objects, and the outlet/action graph.  No chunk -> just the
    // layout (identical to load()).  v1 restriction: an outlet OWNER and an action TARGET must be
    // `owner` or a top-level object (both UXDesignable already) — a designable VIEW in those roles
    // awaits an Object* -> protocol downcast (COMPILER-THREAD #9).
    static UXViewTree* loadWired(u8* path, i32 treeIndex, UXDesignable* owner)
        {
        pointer err = (pointer)0;
        return UXNib.loadDoc(rscload_file(path, (pointer)&err), treeIndex, owner);
        }
    // Same, from an in-memory .rsc image (a generated nib, or a test).
    static UXViewTree* loadWiredMem(u8* data, i32 len, i32 treeIndex, UXDesignable* owner)
        {
        pointer err = (pointer)0;
        return UXNib.loadDoc(rscload_mem(data, (u32)len, (pointer)&err), treeIndex, owner);
        }
    static UXViewTree* loadDoc(pointer doc, i32 treeIndex, UXDesignable* owner)
        {
        if (doc == (pointer)0)
            {
            return (UXViewTree*)0;
            }
        if (treeIndex >= rscload_ntrees(doc))
            {
            rscload_free(doc);
            return (UXViewTree*)0;
            }
        OBJECT* t = (OBJECT*)rscload_tree(doc, treeIndex);
        if (t == (OBJECT*)0)
            {
            rscload_free(doc);
            return (UXViewTree*)0;
            }

        u16 n = (u16)0;
        while (n < (u16)2000)
            {
            u16 f = t[n].ob_flags;
            n = n + (u16)1;
            if ((f & (u16)OF_LASTOB) != (u16)0)
                {
                break;
                }
            }

        UXViewTree* vt = new UXViewTree();
        vt.adopt((pointer)t, n);

        // Views: a G_USERDEF the chunk names becomes that subclass; everything else by type.
        i32 ncl = rscload_nib_present(doc) != (i32)0 ? rscload_nib_nclassov(doc) : (i32)0;
        for (u16 i = (u16)0; i < n; i = i + (u16)1)
            {
            u8* cls = UXNib.classOverride(doc, ncl, treeIndex, (i32)i);
            UXView* v = cls != (u8*)0 ? (UXView * ?) UXNib.make(cls) : (UXView*)0;
            if (v == (UXView*)0)
                {
                v = UXNib.viewForType((u16)(t[i].ob_type & (u16)$00FF));
                }
            v.adoptObject(vt, i);
            }

        // Top-level objects, held as Object*; the loader downcasts to UXDesignable* when wiring (#9).
        Object* tops[64];
        i32 topIds[64];
        i32 ntop = (i32)0;
        i32 nto = rscload_nib_present(doc) != (i32)0 ? rscload_nib_ntopobj(doc) : (i32)0;
        for (i32 i = (i32)0; i < nto && ntop < (i32)64; i = i + (i32)1)
            {
            i32 id = (i32)0;
            u8* cls = rscload_nib_topobj(doc, i, &id);
            tops[ntop] = UXNib.make(cls);
            topIds[ntop] = id;
            ntop = ntop + (i32)1;
            }

        // Connections.  Each Ref resolves to an Object* (view / top-level / owner); the designable
        // side is then downcast to UXDesignable* (#9), so an outlet owner / action target can be ANY
        // of them — including a designable VIEW as the target, or a top-level object as a value.
        // Resolved inline (a top-level array can't cross the <UXKit> library boundary as a parameter).
        i32 ncn = rscload_nib_present(doc) != (i32)0 ? rscload_nib_nconn(doc) : (i32)0;
        for (i32 i = (i32)0; i < ncn; i = i + (i32)1)
            {
            i32 kind = (i32)0;
            i32 ss = (i32)0;
            i32 sa = (i32)0;
            i32 sb = (i32)0;
            i32 ds = (i32)0;
            i32 da = (i32)0;
            i32 db = (i32)0;
            u8* member = rscload_nib_conn(doc, i, &kind, &ss, &sa, &sb, &ds, &da, &db);

            // Resolve src (ss,sa,sb) to an Object*.  space 0 view: sb = obj index; space 1 top: sa =
            // id; space 2 owner.
            Object* srcObj = (Object*)0;
            if (ss == (i32)0)
                { srcObj = (Object* ?)vt.viewAt((u16)sb);
                }
            else if (ss == (i32)1)
                {
                for (i32 j = (i32)0; j < ntop; j = j + (i32)1)
                    {
                    if (topIds[j] == sa)
                        {
                        srcObj = tops[j];
                        break;
                        }
                    }
                }
            else if (ss == (i32)2)
                {
                srcObj = (Object*)owner;
                }
            // Resolve dst (ds,da,db) to an Object* the same way.
            Object* dstObj = (Object*)0;
            if (ds == (i32)0)
                { dstObj = (Object* ?)vt.viewAt((u16)db);
                }
            else if (ds == (i32)1)
                {
                for (i32 j = (i32)0; j < ntop; j = j + (i32)1)
                    {
                    if (topIds[j] == da)
                        {
                        dstObj = tops[j];
                        break;
                        }
                    }
                }
            else if (ds == (i32)2)
                {
                dstObj = (Object*)owner;
                }

            if (kind == (i32)0)
                {
                // OUTLET: src.member = dst.  src is the designable side; dst is any object value.
                UXDesignable* ud = (UXDesignable* ?)srcObj;
                if (ud != (UXDesignable*)0)
                    {
                    ud.setOutlet(member, dstObj);
                    }
                }
            else
                {
                // ACTION: dst.member (a method on the target) bound to the src control's action.
                UXDesignable* ud = (UXDesignable* ?)dstObj;
                UXControl* ctl = (UXControl* ?)srcObj;
                if (ud != (UXDesignable*)0 && ctl != (UXControl*)0)
                    {
                    ud.wireAction(member, ctl);
                    }
                }
            }
        return vt;
        }
    }
