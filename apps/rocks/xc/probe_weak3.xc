// probe_weak3.xc — a `weak:` field declared ALONGSIDE `callback` fields.
//
// Narrowed from a Rocks crash: writing RKEditOverlay.selection (weak) freed the
// unrelated model object being assigned.  A weak field on its own is fine
// (probe_weak2), and callbacks are auto-zeroing too -- so the suspicion is that
// a class carrying BOTH gets its weak-slot bookkeeping confused.
//
// Run under MallocScribble=1.
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

    // A: weak only  (probe_weak2 shape -- known good)
    class WeakOnly : Object
    {
    weak : Thing* sel;
    void init(void)
        {
        sel = (Thing*)0;
        }
    }

    // B: weak FOLLOWED BY callbacks -- the RKEditOverlay shape
    class WeakThenCallbacks : Object
    {
    Thing* strongOne;
    weak : Thing* sel;
    callback a void(Thing* t);
    callback b void(Thing* t);
    callback c void(Thing* t);
    void init(void)
        {
        strongOne = (Thing*)0;
        sel = (Thing*)0;
        a = (callback void(Thing * t))0;
        b = (callback void(Thing * t))0;
        c = (callback void(Thing * t))0;
        }
    }

    // C: callbacks FIRST, then weak
    class CallbacksThenWeak : Object
    {
    callback a void(Thing* t);
    callback b void(Thing* t);
    weak : Thing* sel;
    void init(void)
        {
        a = (callback void(Thing * t))0;
        b = (callback void(Thing * t))0;
        sel = (Thing*)0;
        }
    }

    // D: the weak field on a DEEP SUBCLASS, which is where RKEditOverlay lives
    // (RKEditOverlay : UXShieldView : UXView : Object), each level carrying fields.
    class Base1 : Object
    {
    i32 f1;
    i32 f2;
    Array<Thing>* list1;
    Thing* obj1;
    void init(void)
        {
        f1 = (i32)1;
        f2 = (i32)2;
        list1 = new Array();
        obj1 = (Thing*)0;
        }
    } class Base2 : Base1
    {
    i32 g1;
    Array<Thing>* list2;
    void init(void)
        {
        super.init();
        g1 = (i32)3;
        list2 = new Array();
        }
    } class Deep : Base2
    {
    Thing* strongOne;
    weak : Thing* sel;
    callback a void(Thing* t);
    callback b void(Thing* t);
    callback c void(Thing* t);
    void init(void)
        {
        super.init();
        strongOne = (Thing*)0;
        sel = (Thing*)0;
        a = (callback void(Thing * t))0;
        b = (callback void(Thing * t))0;
        c = (callback void(Thing * t))0;
        }
    }

    bool
    dead(Thing* t)
    {
    u64 k = (u64)(pointer)t.kids;
    return k == (u64)0 || (k & (u64)$FF) == (u64)$55 || t.tag != (i32)7;
    }
i32 gFails;
void check(u8* what, Array<Thing>* owner)
    {
    for (i32 i = (i32)0; i < (i32)owner.count(); i = i + (i32)1)
        {
        if (dead((Thing* ?)owner.get((u16)i)))
            {
            Stdio.printf("  FAIL %s: element %d freed while still held\n", what, (i16)i);
            gFails = gFails + (i32)1;
            return;
            }
        }
    Stdio.printf("  ok   %s\n", what);
    }
Array<Thing>* mk(void)
    {
    Array<Thing>* a = new Array();
    for (i32 i = (i32)0; i < (i32)10; i = i + (i32)1)
        {
        a.add(new Thing());
        }
    return a;
    }

void main(void)
    {
    gFails = (i32)0;

    Array<Thing>* a1 = mk();
    WeakOnly* w1 = new WeakOnly();
    for (i32 n = (i32)0; n < (i32)200; n = n + (i32)1)
        { w1.sel = (Thing* ?)a1.get((u16)(n % (i32)10));
        }
    check((u8*)"weak only                ", a1);

    Array<Thing>* a2 = mk();
    WeakThenCallbacks* w2 = new WeakThenCallbacks();
    for (i32 n = (i32)0; n < (i32)200; n = n + (i32)1)
        { w2.sel = (Thing* ?)a2.get((u16)(n % (i32)10));
        }
    check((u8*)"weak, then callbacks     ", a2);

    Array<Thing>* a3 = mk();
    CallbacksThenWeak* w3 = new CallbacksThenWeak();
    for (i32 n = (i32)0; n < (i32)200; n = n + (i32)1)
        { w3.sel = (Thing* ?)a3.get((u16)(n % (i32)10));
        }
    check((u8*)"callbacks, then weak     ", a3);

    Array<Thing>* a4 = mk();
    Deep* w4 = new Deep();
    for (i32 n = (i32)0; n < (i32)200; n = n + (i32)1)
        { w4.sel = (Thing* ?)a4.get((u16)(n % (i32)10));
        }
    check((u8*)"weak on a DEEP subclass  ", a4);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: all shapes safe\n");
        }
    else
        {
        Stdio.printf("FAIL: %d shape(s)\n", (i16)gFails);
        }
    }
