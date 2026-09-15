// probe_weak2.xc — assigning a PARAMETER to a `weak:` field, inside a setter,
// with a DIFFERENT object each time.
//
// This is the exact shape of RKEditOverlay.setSelection:
//     weak: RKObject* selection;
//     void setSelection(RKObject* o) { selection = o; }
// called once per click with whatever the pointer is over.
//
// Run under MallocScribble=1 so a freed object is obvious at once.
#import <Stdio.xc>
#import "Array.xc"

class Thing : Object
    {
    i32 tag;
    Array<Thing>* kids;
    void init(void)
        {
        tag = (i32)7;
        kids = new Array();
        }
    }

    class Holder : Object
    {
    weak : Thing* sel;
    void init(void)
        {
        sel = (Thing*)0;
        }
    // <- the whole suspect
    void setSel(Thing* o)
        {
        sel = o;
        }
    }

    class StrongHolder : Object
    {
    Thing* sel;
    void init(void)
        {
        sel = (Thing*)0;
        }
    // the control case
    void setSel(Thing* o)
        {
        sel = o;
        }
    }

    bool
    dead(Thing* t)
    {
    u64 k = (u64)(pointer)t.kids;
    return k == (u64)0 || (k & (u64)$FF) == (u64)$55 || t.tag != (i32)7;
    }

i32 check(u8* what, Array<Thing>* owner)
    {
    for (i32 i = (i32)0; i < (i32)owner.count(); i = i + (i32)1)
        {
        if (dead((Thing* ?)owner.get((u16)i)))
            {
            Stdio.printf("  FAIL %s: element %d was freed while the array still held it\n", what, (i16)i);
            return (i32)1;
            }
        }
    Stdio.printf("  ok   %s: every element intact\n", what);
    return (i32)0;
    }

void main(void)
    {
    i32 fails = (i32)0;

    // A weak SETTER, cycling through different objects -- the Rocks shape.
    Array<Thing>* a = new Array();
    for (i32 i = (i32)0; i < (i32)10; i = i + (i32)1)
        {
        a.add(new Thing());
        }
    Holder* h = new Holder();
    for (i32 n = (i32)0; n < (i32)200; n = n + (i32)1)
        {
        h.setSel((Thing* ?)a.get((u16)(n % (i32)10)));
        }
    fails = fails + check((u8*)"weak setter, rotating targets", a);

    // The same, but assigning the field DIRECTLY rather than through a method.
    Array<Thing>* b = new Array();
    for (i32 i = (i32)0; i < (i32)10; i = i + (i32)1)
        {
        b.add(new Thing());
        }
    Holder* h2 = new Holder();
    for (i32 n = (i32)0; n < (i32)200; n = n + (i32)1)
        {
        h2.sel = (Thing* ?)b.get((u16)(n % (i32)10));
        }
    fails = fails + check((u8*)"weak field assigned directly ", b);

    // A STRONG setter, same rotation -- this must be fine, and says whether the
    // problem is `weak:` specifically or parameter passing in general.
    Array<Thing>* c = new Array();
    for (i32 i = (i32)0; i < (i32)10; i = i + (i32)1)
        {
        c.add(new Thing());
        }
    StrongHolder* s = new StrongHolder();
    for (i32 n = (i32)0; n < (i32)200; n = n + (i32)1)
        {
        s.setSel((Thing* ?)c.get((u16)(n % (i32)10)));
        }
    fails = fails + check((u8*)"strong setter, rotating      ", c);

    // TWO weak fields on DIFFERENT objects pointing at the same target, both
    // rotating -- which is what Rocks does: RKDrag.target and
    // RKEditOverlay.selection both weakly reference the picked object.
    Array<Thing>* e = new Array();
    for (i32 i = (i32)0; i < (i32)10; i = i + (i32)1)
        {
        e.add(new Thing());
        }
    Holder* h3 = new Holder();
    Holder* h4 = new Holder();
    for (i32 n = (i32)0; n < (i32)200; n = n + (i32)1)
        {
        Thing* t = (Thing* ?)e.get((u16)(n % (i32)10));
        h3.setSel(t);
        h4.setSel(t);
        }
    fails = fails + check((u8*)"two weak refs to one target  ", e);

    // Three, with one of them cleared in between -- the drag machine clears
    // target on every begin while the overlay keeps its selection.
    Array<Thing>* f = new Array();
    for (i32 i = (i32)0; i < (i32)10; i = i + (i32)1)
        {
        f.add(new Thing());
        }
    Holder* h5 = new Holder();
    Holder* h6 = new Holder();
    Holder* h7 = new Holder();
    for (i32 n = (i32)0; n < (i32)400; n = n + (i32)1)
        {
        Thing* t = (Thing* ?)f.get((u16)(n % (i32)10));
        h5.setSel((Thing*)0);
        h5.setSel(t);
        h6.setSel(t);
        h7.setSel((Thing* ?)f.get((u16)((n + (i32)3) % (i32)10)));
        }
    fails = fails + check((u8*)"three weak refs, one cleared ", f);

    if (fails == (i32)0)
        {
        Stdio.printf("PASS: weak assignment does not release\n");
        }
    else
        {
        Stdio.printf("FAIL: %d case(s)\n", (i16)fails);
        }
    }
