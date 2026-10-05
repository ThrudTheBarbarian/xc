// RKWiring.xc — outlets and actions, as the designer makes them.
//
// A line may be drawn either way: from an object to a control offers the object's outlets that can
// hold the control AND its actions the control could fire, so no-one has to remember which end
// Interface Builder wants a line started from.
//
// An END is what a connection line is drawn from or to: a control in the form, File's Owner,
// First Responder, or one of the document's objects.  Dropping one end on another offers the
// members that fit (wireChoices), and choosing one makes the connection (connect), in the scope
// the designer has chosen: every layout of the form, by default, or some of them.
//
//   control -> object        an ACTION: the control fires one of the object's actions
//   object  -> control       an OUTLET: one of the object's outlets that can hold that control
//   object  -> object        an OUTLET to another object
//   control -> control       either, when the first is a designable view of a custom class
//
// Scopes are sets of layout themes (UXRscConnection.themeBit).  The presets are what a designer
// means: all layouts, one form factor in either orientation, or just the layout on the canvas.
#import "Array.xc"
#import "UXRscModel.xc"
#import "UXNib.xc"
#import "RKOutline.xc"
#import "RKClasses.xc"

// One end of a connection, in the editor's terms.
class RKEnd : Object
    {
    i32 kind;         // RKON_VIEW, RKON_OWNER, RKON_FIRSTR or RKON_OBJECT
    UXRscObject* obj; // RKON_VIEW
    i32 topId;        // RKON_OBJECT

    static RKEnd* view(UXRscObject* o)
        {
        RKEnd* e = new RKEnd();
        e.kind = (i32)RKON_VIEW;
        e.obj = o;
        return e;
        }
    static RKEnd* placeholder(i32 kind, i32 topId)
        {
        RKEnd* e = new RKEnd();
        e.kind = kind;
        e.topId = topId;
        return e;
        }
    bool isView(void)
        {
        return kind == (i32)RKON_VIEW;
        }
    }

// A member offered at a drop: an outlet or an action, and which way the connection goes.
class RKChoice2 : Object
    {
    i32 kind;   // UXR_CONN_OUTLET or UXR_CONN_ACTION
    u8* member;
    u8* type;   // the outlet's type, or the action's sender type
    bool swap;  // an action offered on a line drawn from its target to the control that fires it
    }

// Scope presets, in the order the Connections tab offers them.
#define RKSC_ALL 0
#define RKSC_DESKTOP 1
#define RKSC_TABLET 2
#define RKSC_PHONE 3
#define RKSC_THIS 4
#define RKSC_CUSTOM 5

class RKWiring : Object
    {
    // ---- classes of ends -----------------------------------------------------------------------
    // The class an end is: a control's override or its type's UXKit class, an object's class,
    // File's Owner's.  First Responder has none.
    static u8* classOf(UXRscDoc* d, UXRscTree* t, RKEnd* e)
        {
        if (e.kind == (i32)RKON_VIEW)
            {
            u8* c = d.classOf(t, e.obj);
            return c != (u8*)0 && c[0] != (u8)0 ? c : UXNib.defaultClassFor(e.obj.type);
            }
        if (e.kind == (i32)RKON_OBJECT)
            {
            UXRscTopObject* to = d.topObjectById(e.topId);
            return to != (UXRscTopObject*)0 && to.cls[0] != (u8)0 ? to.cls : (u8*)"Object";
            }
        if (e.kind == (i32)RKON_OWNER)
            {
            return d.ownerClass[0] != (u8)0 ? d.ownerClass : (u8*)"Object";
            }
        return (u8*)"";
        }
    // The ref a connection stores for an end (a control by logical id, so it holds in every layout).
    static UXRscRef* refOf(UXRscDoc* d, UXRscTree* t, RKEnd* e)
        {
        if (e.kind == (i32)RKON_VIEW)
            {
            return d.refFor(t, e.obj);
            }
        if (e.kind == (i32)RKON_OBJECT)
            {
            return UXRscRef.make((i32)UXR_REF_TOP, e.topId, (i32)0);
            }
        if (e.kind == (i32)RKON_FIRSTR)
            {
            return UXRscRef.make((i32)UXR_REF_FIRSTR, (i32)0, (i32)0);
            }
        return UXRscRef.make((i32)UXR_REF_OWNER, (i32)0, (i32)0);
        }
    // Whether a stored ref names this end (in the layout `t`, for a control).
    static bool names(UXRscDoc* d, UXRscTree* t, UXRscRef* r, RKEnd* e)
        {
        if (e.kind == (i32)RKON_VIEW)
            {
            return r.space == (i32)UXR_REF_LOGICAL && e.obj.logicalId != (i32)0 && r.a == d.formIdOf(t) && r.b == e.obj.logicalId;
            }
        if (e.kind == (i32)RKON_OBJECT)
            {
            return r.space == (i32)UXR_REF_TOP && r.a == e.topId;
            }
        if (e.kind == (i32)RKON_FIRSTR)
            {
            return r.space == (i32)UXR_REF_FIRSTR;
            }
        return r.space == (i32)UXR_REF_OWNER;
        }

    // ---- what a drop offers ----------------------------------------------------------------------
    // The members that fit a line drawn from `src` to `dst`: the target's actions when a control is
    // dropped on something that has them, and the source's outlets that can hold the target.
    static Array<RKChoice2>* wireChoices(UXRscDoc* d, UXRscTree* t, RKClassBook* book, RKEnd* src, RKEnd* dst)
        {
        Array<RKChoice2>* out = new Array();
        u8* sc = RKWiring.classOf(d, t, src);
        u8* dc = RKWiring.classOf(d, t, dst);
        // an action: a control fires a method of the target
        if (src.isView())
            {
            if (dst.kind == (i32)RKON_FIRSTR)
                {
                // First Responder takes the action of whatever has the focus: every action any
                // known class declares is a candidate
                RKWiring.allActions(book, out);
                }
            else
                {
                Array<RKMember>* as = book.actionsOf(dc);
                for (u32 i = (u32)0; i < as.count(); i = i + (u32)1)
                    {
                    RKMember* m = (RKMember* ?)as.get(i);
                    RKWiring.offer(out, (i32)UXR_CONN_ACTION, m.name, m.type);
                    }
                }
            }
        // an action drawn the other way: from the target to the control
        if (dst.isView() && !src.isView())
            {
            if (src.kind == (i32)RKON_FIRSTR)
                {
                Array<RKChoice2>* all = new Array();
                RKWiring.allActions(book, all);
                for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                    {
                    RKChoice2* c = (RKChoice2* ?)all.get(i);
                    RKWiring.offerSwapped(out, c.member, c.type);
                    }
                }
            else
                {
                Array<RKMember>* as = book.actionsOf(sc);
                for (u32 i = (u32)0; i < as.count(); i = i + (u32)1)
                    {
                    RKMember* m = (RKMember* ?)as.get(i);
                    RKWiring.offerSwapped(out, m.name, m.type);
                    }
                }
            }
        // an outlet: the source holds the target
        if (src.kind != (i32)RKON_FIRSTR && dst.kind != (i32)RKON_FIRSTR)
            {
            Array<RKMember>* os = book.outletsOf(sc);
            for (u32 i = (u32)0; i < os.count(); i = i + (u32)1)
                {
                RKMember* m = (RKMember* ?)os.get(i);
                if (book.fits(dc, m.type))
                    {
                    RKWiring.offer(out, (i32)UXR_CONN_OUTLET, m.name, m.type);
                    }
                }
            }
        return out;
        }
    static void allActions(RKClassBook* book, Array<RKChoice2>* out)
        {
        for (u32 i = (u32)0; i < book.classes.count(); i = i + (u32)1)
            {
            RKClass* c = (RKClass* ?)book.classes.get(i);
            for (u32 k = (u32)0; k < c.actions.count(); k = k + (u32)1)
                {
                RKMember* m = (RKMember* ?)c.actions.get(k);
                RKWiring.offer(out, (i32)UXR_CONN_ACTION, m.name, m.type);
                }
            }
        }
    static void offerSwapped(Array<RKChoice2>* out, u8* member, u8* type)
        {
        for (u32 i = (u32)0; i < out.count(); i = i + (u32)1)
            {
            RKChoice2* c = (RKChoice2* ?)out.get(i);
            if (c.kind == (i32)UXR_CONN_ACTION && RKClassBook.seq(c.member, member))
                {
                return;
                }
            }
        RKChoice2* c = new RKChoice2();
        c.kind = (i32)UXR_CONN_ACTION;
        c.member = member;
        c.type = type;
        c.swap = true;
        out.add(c);
        }
    static void offer(Array<RKChoice2>* out, i32 kind, u8* member, u8* type)
        {
        for (u32 i = (u32)0; i < out.count(); i = i + (u32)1)
            {
            RKChoice2* c = (RKChoice2* ?)out.get(i);
            if (c.kind == kind && RKClassBook.seq(c.member, member))
                {
                return;
                }
            }
        RKChoice2* c = new RKChoice2();
        c.kind = kind;
        c.member = member;
        c.type = type;
        c.swap = false;
        out.add(c);
        }

    // ---- making and breaking ---------------------------------------------------------------------
    // Connect.  An outlet holds one thing per layout, so a new outlet connection replaces an older
    // one from the same source and member whose scope covers the same layouts (its scope loses
    // those layouts, and it goes if none are left).
    static UXRscConnection* connect(UXRscDoc* d, UXRscTree* t, RKEnd* src, RKEnd* dst, RKChoice2* ch, u32 scope)
        {
        UXRscConnection* c = new UXRscConnection();
        c.kind = ch.kind;
        c.member = ch.member;
        c.scope = scope;
        if (ch.kind == (i32)UXR_CONN_ACTION)
            {
            RKEnd* control = ch.swap ? dst : src;
            RKEnd* target = ch.swap ? src : dst;
            c.src = RKWiring.refOf(d, t, control);
            c.dst = RKWiring.refOf(d, t, target);
            // a control sends one action per layout, likewise
            RKWiring.yieldTo(d, c, true);
            }
        else
            {
            c.src = RKWiring.refOf(d, t, src);  // the holder
            c.dst = RKWiring.refOf(d, t, dst);  // what it holds
            RKWiring.yieldTo(d, c, false);
            }
        d.connections.add(c);
        return c;
        }
    // Older connections that the new one supersedes in its layouts: an outlet's (same holder,
    // same member) or a control's sent action (same control).
    static void yieldTo(UXRscDoc* d, UXRscConnection* n, bool sentAction)
        {
        u32 i = (u32)0;
        while (i < d.connections.count())
            {
            UXRscConnection* o = (UXRscConnection* ?)d.connections.get(i);
            bool same = o.kind == n.kind && o.src.same(n.src) &&
                        (sentAction || RKClassBook.seq(o.member, n.member));
            if (!same)
                {
                i = i + (u32)1;
                continue;
                }
            u32 had = o.scope == (u32)0 ? RKWiring.fullScope() : o.scope;
            u32 takes = n.scope == (u32)0 ? RKWiring.fullScope() : n.scope;
            if ((had & takes) == (u32)0)
                {
                i = i + (u32)1; // other layouts: both stand
                continue;
                }
            u32 left = had & ~takes;
            if (left == (u32)0)
                {
                d.connections.removeAt(i);
                continue;
                }
            o.scope = left;
            i = i + (u32)1;
            }
        }
    // Every theme bit in use: 4 form-factor classes x 3 orientations.
    static u32 fullScope(void)
        {
        return (u32)$FFF;
        }
    static void disconnect(UXRscDoc* d, UXRscConnection* c)
        {
        for (u32 i = (u32)0; i < d.connections.count(); i = i + (u32)1)
            {
            if ((UXRscConnection* ?)d.connections.get(i) == c)
                {
                d.connections.removeAt(i);
                return;
                }
            }
        }

    // ---- what touches an end -----------------------------------------------------------------
    // Every connection with this end at either side, in document order.
    static Array<UXRscConnection>* connectionsOf(UXRscDoc* d, UXRscTree* t, RKEnd* e)
        {
        Array<UXRscConnection>* out = new Array();
        for (u32 i = (u32)0; i < d.connections.count(); i = i + (u32)1)
            {
            UXRscConnection* c = (UXRscConnection* ?)d.connections.get(i);
            if (RKWiring.names(d, t, c.src, e) || RKWiring.names(d, t, c.dst, e))
                {
                out.add(c);
                }
            }
        return out;
        }

    // ---- scopes ------------------------------------------------------------------------------------
    // The theme the layout `t` was drawn for: its variant's form factor and orientation, or `any`.
    static u32 themeOf(UXRscDoc* d, UXRscTree* t)
        {
        UXRscForm* f = d.formOf(t);
        UXRscVariant* v = f != (UXRscForm*)0 ? f.variantFor(t) : (UXRscVariant*)0;
        if (v == (UXRscVariant*)0)
            {
            return UXRscConnection.themeBit((i32)UXR_V_ANY, (i32)UXR_V_ORIENT_NONE);
            }
        return UXRscConnection.themeBit(v.klass, v.orient);
        }
    // A preset's scope.  RKSC_THIS needs the layout on the canvas.
    static u32 scopeOf(i32 preset, u32 thisTheme)
        {
        if (preset == (i32)RKSC_DESKTOP)
            {
            return RKWiring.factor((i32)UXR_V_DESKTOP);
            }
        if (preset == (i32)RKSC_TABLET)
            {
            return RKWiring.factor((i32)UXR_V_TABLET);
            }
        if (preset == (i32)RKSC_PHONE)
            {
            return RKWiring.factor((i32)UXR_V_PHONE);
            }
        if (preset == (i32)RKSC_THIS)
            {
            return thisTheme;
            }
        return (u32)0;
        }
    // A form factor in any orientation.  The desktop has no orientation: its one theme.
    static u32 factor(i32 klass)
        {
        if (klass == (i32)UXR_V_DESKTOP)
            {
            return UXRscConnection.themeBit(klass, (i32)UXR_V_ORIENT_NONE);
            }
        return UXRscConnection.themeBit(klass, (i32)UXR_V_ORIENT_NONE) |
               UXRscConnection.themeBit(klass, (i32)UXR_V_ORIENT_PORTRAIT) |
               UXRscConnection.themeBit(klass, (i32)UXR_V_ORIENT_LANDSCAPE);
        }
    // Which preset a scope is, or RKSC_CUSTOM.
    static i32 presetOf(u32 scope, u32 thisTheme)
        {
        for (i32 p = (i32)RKSC_ALL; p <= (i32)RKSC_PHONE; p = p + (i32)1)
            {
            if (RKWiring.scopeOf(p, thisTheme) == scope)
                {
                return p;
                }
            }
        if (scope == thisTheme)
            {
            return (i32)RKSC_THIS;
            }
        return (i32)RKSC_CUSTOM;
        }
    static u8* presetName(i32 p)
        {
        if (p == (i32)RKSC_ALL)
            {
            return (u8*)"All layouts";
            }
        if (p == (i32)RKSC_DESKTOP)
            {
            return (u8*)"Desktop";
            }
        if (p == (i32)RKSC_TABLET)
            {
            return (u8*)"Tablet";
            }
        if (p == (i32)RKSC_PHONE)
            {
            return (u8*)"Phone";
            }
        if (p == (i32)RKSC_THIS)
            {
            return (u8*)"This layout";
            }
        return (u8*)"Some layouts";
        }
    // Whether a connection binds in the layout `t`, and whether both its ends are there.
    static bool inScopeHere(UXRscDoc* d, UXRscTree* t, UXRscConnection* c)
        {
        u32 th = RKWiring.themeOf(d, t);
        return c.scope == (u32)0 || (c.scope & th) != (u32)0;
        }
    }
