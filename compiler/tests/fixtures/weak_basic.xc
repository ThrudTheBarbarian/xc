// weak_basic.xc — weak reference auto-zeroes when its pointee is freed.
//
// Validates Phase 3 PR 3: the basic weak-reference round trip.
//   • A strong local allocates a class instance.
//   • A weak slot is assigned from that strong local (no retain).
//   • When the strong local's scope exits, its refcount hits 0 and
//     the dealloc path calls _weak_zero_all_for, zeroing the weak
//     slot before the block is freed.
//
// The weak slot lives at module scope so it outlives the helper
// function where the strong local is allocated. Module-scope
// globals are zero-inited by the startup convention, so the slot
// starts as null and we can read back the same address safely.
//
// Test surface:
//   T1  weak slot non-null while strong is alive
//   T2  weak slot zeroed after strong's scope exit

#import "Stdio.xc"
#import "Assert.xc"

class Leaf
{
    u8 tag;
}

// Module-scope weak slot. Starts zero by BSS convention, so the
// first read in `fillAndDrop` is well-defined.
weak:Leaf* gW;

void fillAndDrop(void)
{
    Leaf* s = new Leaf();
    s.tag = (u8)42;
    gW = s;                         // weak assign — register in side table
    Assert.isNotNull((pointer)gW);  // T1: w tracks s while s is alive
    // Scope exit: s releases → refcount 0 → _weak_zero_all_for
    // walks the side table and zeroes gW before Leaf is freed.
}

void main(void)
{
    Assert.reset();
    fillAndDrop();
    Assert.isNull((pointer)gW);     // T2: w auto-zeroed after s freed
    Assert.summary();
    return;
}
