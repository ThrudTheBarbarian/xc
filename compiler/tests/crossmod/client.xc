#import "Stdio.xc"
#import <bmlib>

u16 clientFn(void)
    {
    return (u16)77;
    }

class Target
    {
    u16 tag;
    u16 ping(void)
        {
        return self.tag;
        }
    }

    Target* gT;

void bindAndDrop(void)
    {
    LibButton* b = new LibButton();
    gT = new Target();
    gT.tag = (u16)55;

    // A BOUND ^ : recv is a real CLIENT object, stored in the LIBRARY's weak slot.
    b.setAction(&gT.ping);
    Stdio.printf("bound-fire=%d\n", b.fire());

    gT = (Target*)0;                            // the target dies — the LIB's slot must zero
    Stdio.printf("after-death=%d\n", b.fire()); // 0 = weak-zeroed, not a dangle
    }

// Every position an imported struct can appear in. Before the fix, the two that
// "worked" were the dangerous ones: a struct PARAMETER parsed as u8 and truncated
// silently, while the rest were honest parse errors.
XGRect makeRect(u16 w, u16 h)
    {
    XGRect r;
    r.x = (u16)1;
    r.y = (u16)2;
    r.w = w;
    r.h = h;
    return r;
    }

class Holder
    {
    XGRect bounds;
    u16 area(void)
        {
        return self.bounds.w * self.bounds.h;
        }
    }

    void
    importedStructs(void)
    {
    XGRect r;
    r.x = (u16)1;
    r.y = (u16)2;
    r.w = (u16)3;
    r.h = (u16)4; // local
    Stdio.printf("st-local=%d,%d,%d,%d\n", r.x, r.y, r.w, r.h);

    XGView* v = new XGView();
    Stdio.printf("st-into-lib=%d\n", v.area(r)); // by value INTO the lib
    XGRect b = v.bounds();
    Stdio.printf("st-from-lib=%d,%d,%d,%d\n", b.x, b.y, b.w, b.h); // by value OUT of the lib

    XGRect m = makeRect((u16)5, (u16)6); // return type
    Stdio.printf("st-ret=%d\n", m.w * m.h);

    Holder* h = new Holder();
    h.bounds = r; // class field
    Stdio.printf("st-field=%d\n", h.area());

    XGRect* p = new XGRect;
    p.w = (u16)7;
    p.h = (u16)8; // pointer local
    Stdio.printf("st-ptr=%d\n", p.w * p.h);
    }

// Everything else a library exports. The vtable-slot case is the sharp one: slots
// are numbered per compilation unit, and under --emit-lib EVERY instance method is
// an override root — so the library's numbering and the client's could never agree,
// and dispatch through a `Proto@` receiver read the WRONG SLOT and jumped to garbage.
// That breaks the delegate pattern exactly where it is most wanted: across a .so.
// The client now ADOPTS the library's numbering (its vtables are already emitted).
void importedApi(void)
    {
    MDerived* d = new MDerived();
    Stdio.printf("api-method=%d\n", d.draw());        // 22
    Stdio.printf("api-inherit=%d\n", d.baseOnly());   // 11 — inherited
    Stdio.printf("api-static=%d\n", MDerived.stat()); // 33
    Stdio.printf("api-enumconst=%d\n", (u16)M_BLUE);  // 7
    MColor c = M_RED;
    Stdio.printf("api-enumtype=%d\n", (u16)c); // 3  — the enum TYPE, not just its constants
    MDrawable* p = (MDrawable*)d;
    Stdio.printf("api-proto=%d\n", p.draw());                 // 22 — VTABLE DISPATCH ACROSS THE .so
    Stdio.printf("api-freefn=%d\n", freeAdd((u16)2, (u16)3)); // 5  — a free function
    }

// NB: the client does NOT `#import <GEM>` — the library's interface records that its
// types come from there, and the client re-imports the same .so automatically.
Node* gChild;
OBJECT gTree[2];

void importedWeakAndCTypes(void)
    {
    Node* n = new Node();
    Stdio.printf("wk-tag=%d\n", n.get()); // 1 — ivar offsets agree
    gChild = new Node();
    n.parent = gChild;                                           // write the imported weak field
    Stdio.printf("wk-linked=%d\n", (i16)(n.parent != (Node*)0)); // 1
    gChild = (Node*)0;                                           // the referent dies
    Stdio.printf("wk-zeroed=%d\n", (i16)(n.parent == (Node*)0)); // 1 — weak really works

    gTree[0].ob_w = (i16)123;
    gTree[0].ob_h = (i16)45;
    GHolder* h = new GHolder();
    h.hold(&gTree[0]);
    OBJECT* back = h.objects();
    Stdio.printf("ct-lib-reads=%d\n", h.widthOf()); // 123 — the LIBRARY reads it
    Stdio.printf("ct-app-reads=%d\n", back.ob_h);   // 45  — the APP reads it back
    }

class ATarget
    {
    u16 v;
    u16 hit(void)
        {
        return self.v;
        }
    } ATarget* gTarget;

void weakBoundAcrossSo(void)
    {
    XGControl* c = new XGControl();
    Stdio.printf("wb-tag=%d\n", c.get()); // 7 — the weak ^ reserved its links

    gTarget = new ATarget();
    gTarget.v = (u16)88;
    c.setAction(&gTarget.hit);              // target/action, across the .so
    Stdio.printf("wb-fire=%d\n", c.fire()); // 88

    gTarget = (ATarget*)0;                  // the TARGET dies
    Stdio.printf("wb-dead=%d\n", c.fire()); // 0 — the action auto-zeroed
    }

class MyDel<VDel>
    {
    u16 tick(void)
        {
        return (u16)77;
        }
    }

    void
    importedClassVirtuals(void)
    {
    VApp* a = new VApp();
    Stdio.printf("vt-direct=%d\n", a.boot()); // 200 — devirtualised; always worked
    Stdio.printf("vt-self=%d\n", a.run());    // 200 — the LIBRARY's own virtual self-call
    a.setDel((VDel*)new MyDel());
    Stdio.printf("vt-del=%d\n", a.callDel()); // 77  — library -> client, via a protocol
    }

// A CLIENT subclass of an IMPORTED class, declaring no init of its own.
class XGButton : XGCtl
    {
    u16 extra;
    }

    void
    inheritedInitAcrossSo(void)
    {
    XGCtl* c = new XGCtl();
    Stdio.printf("ii-base=%d,%d\n", c.tag, c.w); // 42,7
    XGLibButton* l = new XGLibButton();
    Stdio.printf("ii-libsub=%d,%d\n", l.tag, l.w); // 42,7 — no-init subclass INSIDE the lib
    XGButton* b = new XGButton();
    Stdio.printf("ii-appsub=%d,%d\n", b.tag, b.w); // 42,7 — CLIENT subclass of a LIB class
    Stdio.printf("ii-vialib=%d\n", b.width());     // 7 — the library reads what it set
    }

i16 main(void)
    {
    LibButton* w = new LibButton();
    Stdio.printf("callNow=%d\n", w.callNow(&clientFn));
    w.setAction(&clientFn); // WIDENED ^ : recv is .text, must NOT register
    Stdio.printf("widened-fire=%d\n", w.fire());
    bindAndDrop();
    importedStructs();
    importedApi();
    importedWeakAndCTypes();
    weakBoundAcrossSo();
    importedClassVirtuals();
    inheritedInitAcrossSo();
    Stdio.printf("done\n");
    return 0;
    }
