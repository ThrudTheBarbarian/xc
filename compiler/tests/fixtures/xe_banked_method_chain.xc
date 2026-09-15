// xe_banked_method_chain.xc — Phase 1c: chained banked-method call
// from inside another :banked method body. Exercises:
//
//   * Sibling :banked method call (`set` from `doubleIt` on the same
//     instance, implicit-self).
//   * Chained call on a banked-pointer ivar (`child.store(x)` in a
//     :banked method body) — receiver is loaded via three (self),Y
//     reads (Phase 1c patched the bank-byte read at offset+2 too)
//     then dispatched through the cloaked-bracket method-call path.

#import "Stdio.xc"
#import "Assert.xc"

class Inner
{
    u16 v;
    void store(u16 x) :banked  { v = x; }
    u16 read(void) :banked     { return v; }
}

class Outer
{
    banked:Inner* child;

    void install(u16 x) :banked
    {
        child = new Inner();
        child.store(x);            // chained banked call from banked body
    }

    void doubleIt(u16 x) :banked
    {
        installAt(x + x);          // sibling call (implicit self)
    }

    void installAt(u16 x) :banked  { child.store(x); }

    u16 fetch(void) :banked        { return child.read(); }
}

void main(void)
{
    Assert.reset();
    Outer* o = new Outer();
    o.install($4242);
    Assert.isEqual(o.fetch(), $4242);   // T1
    o.doubleIt(7);                       // expects child.v = 14 after
    Assert.isEqual(o.fetch(), 14);       // T2
    Assert.summary();
    return;
}
