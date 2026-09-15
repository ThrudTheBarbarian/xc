// arc_weak_return_leak.xc — bug 171. A `weak:` return type must normalise to
// strong: the value returned is a transient +1 (a `new T`, a returnsRetained
// call), not storage, so declaring the return `weak:T@` and having the caller
// treat it as borrowed leaked the +1 unconditionally.
//
// Test surface:
//   T1  a `weak:T@` return of a `new T` frees when the receiving strong local
//       dies (the normalise makes it an ordinary returnsRetained return)
//   T2  a genuine `weak:T@` FIELD is unaffected — still a weak slot, still
//       auto-zeroes when its referent dies

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

u16 gLive = (u16)0;

class Item
{
    u16 v;
    void init(void) { v = (u16)0; gLive = gLive + (u16)1; }
    void dealloc(void) { gLive = gLive - (u16)1; }
}

// The return type is spelled weak: — it normalises to strong, so this is an
// ordinary +1-returning maker.
weak:Item@ makeWeak(void)
{
    Item* p = new Item();
    p.v = (u16)5;
    return p;
}

// A METHOD whose return type is spelled weak: — it normalises to strong too
// (the parser strips weak: from a method return, not only a free function's).
class Factory { weak:Item@ make(void) { Item* p = new Item(); p.v = (u16)9; return p; } }

class Box { weak:Item@ wf; }

void main(void)
{
    // T1 — weak return, strong destination. The object frees at scope exit.
    {
        Item* got = makeWeak();
        Assert.isEqual(got.v, (u16)5);
        Assert.isEqual(gLive, (u16)1);      // alive inside the scope
    }
    Assert.isEqual(gLive, (u16)0);          // T1: freed (was 1 — leaked)

    // T2 — a real weak FIELD is still a weak slot. It borrows a strong-owned
    // object and auto-zeroes when that owner dies.
    Box* b = new Box();
    {
        Item* owner = new Item();
        b.wf = owner;                       // borrowed
        Assert.isTrue(b.wf != 0);           // sees it while alive
    }
    Assert.isTrue(b.wf == 0);               // T2: auto-zeroed after owner died
    Assert.isEqual(gLive, (u16)0);          // no leak

    // T3 — a METHOD weak: return. Same normalisation as a free function's, so
    // the maker's +1 frees at scope exit (was a +1 leak in the port: gLive 1).
    Factory* fac = new Factory();
    {
        Item* got3 = fac.make();
        Assert.isEqual(got3.v, (u16)9);
        Assert.isEqual(gLive, (u16)1);      // alive inside the scope
    }
    Assert.isEqual(gLive, (u16)0);          // T3: freed (was 1 — leaked in the port)

    Assert.summary();
    return;
}
