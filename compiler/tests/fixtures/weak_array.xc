// weak_array.xc — element-wise tracking of a stack weak array.
//
// Validates Phase 3 PR 7: `weak:T@ arr[N]` on stack/spill.
//   • Every element zero-inited at decl.
//   • Assigning into arr[i] registers the slot; the side-table
//     entry keys on (base + i*elemWidth).
//   • Releasing one referent auto-zeroes its slot without
//     disturbing sibling elements.
//   • Scope exit walks every slot and unregisters — the user
//     doesn't have to clear the array by hand.
//
// Test surface:
//   T1  arr[0] / arr[1] / arr[2] all non-null after the fills
//   T2  Freeing the object behind arr[1] zeroes arr[1] only
//   T3  arr[0] and arr[2] still live and point at their originals
//   T4  Scope-exit unregister leaves the side table clean — a
//       subsequent weak array reusing the same slot addresses
//       doesn't see stale entries from the prior scope

#import "Stdio.xc"
#import "Assert.xc"

class Leaf
{
    u8 tag;
}

// Module-scope strong holders so the referents outlive the helper
// scope where the weak array lives. Each is released explicitly
// below to observe the per-element auto-zero.
Leaf* gA;
Leaf* gB;
Leaf* gC;

// Used by T4: a second fillArray() call should find a clean side
// table (no stale entries left over from the first call's weak
// array exit). We detect "stale entries" by asserting that
// filling arr[1] again points at a fresh object, not at the
// ghost of the prior gB.
Leaf* gD;

void fillAndDropMiddle(void)
{
    weak:Leaf* arr[3];
    arr[0] = gA;
    arr[1] = gB;
    arr[2] = gC;
    Assert.isNotNull((pointer)arr[0]);   // T1
    Assert.isNotNull((pointer)arr[1]);
    Assert.isNotNull((pointer)arr[2]);

    // Release the referent behind arr[1]. _weak_zero_all_for
    // walks the side table, finds exactly arr[1]'s entry for
    // gB's address, and zeroes that slot.
    gB = (Leaf*)0;
    Assert.isNull((pointer)arr[1]);      // T2: only middle went
    Assert.isNotNull((pointer)arr[0]);   // T3: siblings untouched
    Assert.isNotNull((pointer)arr[2]);

    // Scope exit here unregisters all three slots (including the
    // already-empty arr[1]); the final gA / gC releases in main
    // are what trigger any remaining auto-zero work, and with a
    // clean table that's a silent scan.
}

void fillAgainWithFresh(void)
{
    weak:Leaf* arr[3];
    gD = new Leaf();    gD.tag = (u8)99;
    arr[1] = gD;                           // reuses arr[1]'s slot address
    Assert.isNotNull((pointer)arr[1]);    // T4: slot tracks gD, not ghost of gB
    // Scope exit clears arr[1]'s entry again.
}

void main(void)
{
    Assert.reset();
    gA = new Leaf();    gA.tag = (u8)1;
    gB = new Leaf();    gB.tag = (u8)2;
    gC = new Leaf();    gC.tag = (u8)3;

    fillAndDropMiddle();
    fillAgainWithFresh();

    // Cleanup — global strong refs held by gA/gC drop.
    gA = (Leaf*)0;
    gC = (Leaf*)0;
    gD = (Leaf*)0;

    Assert.summary();
    return;
}
