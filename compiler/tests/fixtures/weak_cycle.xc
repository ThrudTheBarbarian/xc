// weak_cycle.xc — the canonical cycle-breaking use case for weak
// references. Parent owns Child; Child has a weak back-pointer to
// Parent. Without weak, the strong-strong pair would leak because
// each keeps the other's refcount above zero indefinitely. With
// weak, dropping the last external strong reference to Parent
// cascades cleanly: Parent releases Child, Child's weak back is
// just unregistered, and both blocks return to the heap.
//
// Test surface:
//   T1  After build, both instances are live
//   T2  After dropping the outer Parent reference, BOTH instances
//       get dealloc'd (no leak) — deallocCount bumps by exactly 2

#import "Stdio.xc"
#import "Assert.xc"

u16 deallocCount;

class Parent
{
    // Forward ref is fine — the parser accepts class names before
    // their declaration via the pre-scan. `Child@` is strong, so
    // Parent owns Child.
    Child* kid;
    u8 tag;
    void dealloc(void) { deallocCount = deallocCount + 1; }
}

class Child
{
    weak:Parent* dad;
    u8 tag;
    void dealloc(void) { deallocCount = deallocCount + 1; }
}

Parent* gP;

void build(void)
{
    gP = new Parent();                  gP.tag = (u8)1;
    gP.kid = new Child();               gP.kid.tag = (u8)2;
    gP.kid.dad = gP;                    // weak back-pointer; no refcount bump
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;

    build();
    Assert.isNotNull((pointer)gP);       // T1: both alive
    // The cycle is: gP → kid (strong, +1), kid → dad (weak, +0).
    // Parent's refcount: 1 (held by gP). Child's refcount: 1
    // (held by Parent.kid). No circular strong references.

    gP = (Parent*)0;
    // gP release cascade:
    //   1. gP drops Parent's refcount to 0 → Parent.dealloc fires.
    //   2. Aggregate walker visits Parent's strong kid → decref
    //      Child → refcount 0 → Child.dealloc fires.
    //   3. Walker visits Child's weak dad — just unregisters the
    //      slot from the side table. No decref.
    //   4. Both blocks go back to the heap.
    Assert.isEqual(deallocCount, (u16)2);  // T2: both dealloc'd

    Assert.summary();
    return;
}
