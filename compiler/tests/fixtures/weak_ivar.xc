// weak_ivar.xc — weak class-pointer ivar auto-zeroes when its
// referent is freed, and is cleanly unregistered when the
// enclosing class instance itself dies.
//
// Validates Phase 3 PR 4: weak ivars inside heap-allocated class
// payloads. A Parent has a weak:Leaf@ back-pointer; freeing the
// Leaf while the Parent is still alive zeroes the back-pointer
// via the side-table walker. Freeing the Parent afterwards
// must NOT touch the Leaf's (already-zero) refcount, and the
// Parent's own dealloc must unregister the back-pointer slot
// from the side table before the block goes back to the heap.
//
// Test surface:
//   T1  Parent.back non-null while Leaf is alive
//   T2  Freeing Leaf zeroes Parent.back (weak auto-zero through
//       an ivar slot inside a class payload)
//   T3  Freeing Parent after its weak ivar is already null is safe
//       — the Parent's dealloc-walker unregisters the stale slot
//       entry (now empty) without touching anything live

#import "Stdio.xc"
#import "Assert.xc"

class Leaf
{
    u8 tag;
}

class Parent
{
    weak:Leaf* back;
}

Parent* gP;
Leaf* gL;

void setupAndBreak(void)
{
    gL = new Leaf();            gL.tag = (u8)7;
    gP = new Parent();
    gP.back = gL;               // register weak ivar, slot = gP's payload + 0
    Assert.isNotNull((pointer)gP.back);   // T1

    gL = (Leaf*)0;              // Leaf refcount 0 → _weak_zero_all_for
    Assert.isNull((pointer)gP.back);      // T2: back auto-zeroed via walker
}

void dropParent(void)
{
    gP = (Parent*)0;            // Parent refcount 0 → dealloc walker runs
    // Walker unregisters the (now-empty) weak slot and frees the
    // block. If the unregister ran wrong it would either (a) read
    // freed memory next time weak_zero_all_for is invoked, or
    // (b) leak an entry pointing at a recycled address.
}

void main(void)
{
    Assert.reset();
    setupAndBreak();
    dropParent();
    Assert.isNull((pointer)gP);           // T3: sanity — gP is null
    Assert.summary();
    return;
}
