typedef u16 act_t(void);
typedef u16 act_t2(void);
class LibButton
    {
    act_t ^ action;
    // pass-through: no store
    u16 callNow(act_t ^ a)
        {
        return a();
        }
    // store into a weak ^ ivar
    void setAction(act_t ^ a)
        {
        action = a;
        }
    u16 fire(void)
        {
        if (action)
            {
            return action();
            }
        return (u16)0;
        }
    u16 probeRecvNull(void)
        {
        if (action)
            {
            return (u16)1;
            }
        return (u16)0;
        }
    }

    // An exported STRUCT. Structs are as much part of a library's API as its classes:
    // a method taking XGRect is unusable without the type. They were never serialised
    // into .xtc.iface at all, so the NAME showed up all over the interface (inside
    // signatures, as a string) while the TYPE was nowhere.
    struct XGRect
    {
    u16 x;
    u16 y;
    u16 w;
    u16 h;
    }

    class XGView
    {
    u16 tag;
    // struct BY VALUE in
    u16 area(XGRect r)
        {
        return r.w * r.h;
        }
    XGRect bounds(void)
        {
        XGRect b;
        b.x = (u16)1;
        b.y = (u16)2;
        b.w = (u16)3;
        b.h = (u16)4;
        return b;
        }
    }

    // Exported enum, typedef, free function, protocol, inheritance, static method.
    enum MColor = {M_RED = 3, M_BLUE = 7};
typedef u16 mcb_t(void);
u16 freeAdd(u16 a, u16 b)
    {
    return a + b;
    }

protocol MDrawable
    {
    u16 draw(void);
    }

class MBase
    {
    u16 b;
    u16 baseOnly(void)
        {
        return (u16)11;
        }
    } class MDerived : MBase<MDrawable>
    {
    u16 d;
    u16 draw(void)
        {
        return (u16)22;
        }
    static u16 stat(void)
        {
        return (u16)33;
        }
    }

// A weak: field, and a C type imported from ANOTHER library — the two shapes a
// BINDING library is made of, and neither could cross an interface at all.
//
//   weak:  the qualifier is baked into the type's displayName (`weak:Node@`), so the
//          client looked up `weak:Node` and found nothing. Structural, not incidental:
//          weak: is what stops a view hierarchy being one enormous retain cycle —
//          the responder chain, owner/superview, target/action. Every edge crosses.
//
//   OBJECT: comes from libGEM's DWARF, not from this library's source, so --emit-lib
//          cannot describe it — and must not TRY. It is recorded as a REFERENCE
//          ("this type lives in libGEM"), and the client re-imports the same .so
//          through the same DWARF reader. One source of truth: re-serialising it would
//          let two libraries silently disagree about OBJECT's layout after an aes.h
//          change, and a layout disagreement across a .so is the worst failure there
//          is — nothing type-checks it, nothing reports it.
#import <GEM>

    class Node
    {
    weak : Node* parent; // a weak field, in the interface
    i16 tag;
    void init(void)
        {
        tag = (i16)1;
        }
    // proves the ivar OFFSET agrees
    i16 get(void)
        {
        return tag;
        }
    }

    class GHolder
    {
    OBJECT* objs;
    void init(void)
        {
        objs = (OBJECT*)0;
        }
    // C type as a PARAMETER
    void hold(OBJECT* o)
        {
        objs = o;
        }
    // C type as a RETURN
    OBJECT* objects(void)
        {
        return objs;
        }
    // reads a field: LAYOUT must agree
    i16 widthOf(void)
        {
        return objs.ob_w;
        }
    }

    // weak: on a `^` — the THIRD variant, and the one a UI toolkit leans on hardest:
    // it is target/action. `act_t^` alone crossed, and `weak: T@` alone crossed; the
    // COMBINATION did not, because a weak bound method interns as a DISTINCT type
    // ($wbound_<sig>, not $bound_<sig>) and the importer only knew the latter.
    class XGControl
    {
    weak : act_t2 ^ action;
    i16 tag;
    void init(void)
        {
        tag = (i16)7;
        }
    i16 get(void)
        {
        return tag;
        }
    void setAction(act_t2 ^ a)
        {
        action = a;
        }
    u16 fire(void)
        {
        if (action)
            {
            return action();
            }
        return (u16)0;
        }
    }

    // An exported class that dispatches VIRTUALLY ON ITSELF, and calls back into the
    // client through a protocol. Under --emit-lib every instance method is an override
    // root, so the library DOES dispatch on `self.boot()` — but in the client nothing
    // overrides boot(), so by the client's local rule it is not a root, and the client
    // built NO VTABLE for the imported class at all. `new VApp()` then left the object's
    // vtable pointer NULL.
    //
    // Direct calls devirtualise, so `a.boot()` worked and it all looked fine — right up
    // until the LIBRARY made its own virtual call through a null vtable.
    protocol VDel
    {
    u16 tick(void);
    }

class VApp
    {
    weak : VDel* del;
    u16 v;
    void init(void)
        {
        v = (u16)5;
        }
    u16 boot(void)
        {
        return (u16)200;
        }
    // library-internal virtual call
    u16 run(void)
        {
        return self.boot();
        }
    void setDel(VDel* d)
        {
        del = d;
        }
    u16 callDel(void)
        {
        if (del)
            {
            return del.tick();
            }
        return (u16)0;
        }
    }

    // A base class with an init, for a CLIENT subclass to inherit. A subclass that declares
    // no init of its own ran no initialiser at all — not even the inherited one — and that is
    // exactly what `XGButton : XGControl` looks like. The library must serialise the init it
    // synthesises for its OWN no-init subclass too, or a client instantiating it gets nothing.
    class XGCtl
    {
    u16 tag;
    u16 w;
    void init(void)
        {
        self.tag = (u16)42;
        self.w = (u16)7;
        }
    // the LIBRARY reads what it initialised
    u16 width(void)
        {
        return self.w;
        }
    // no init, INSIDE the library
    } class XGLibButton : XGCtl
    {
    u16 pad;
    }
