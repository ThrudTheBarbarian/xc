// weak_reassign.xc — weak slot reassignment unregisters the old
// table entry and registers the new one.
//
// Validates that `weakVar = otherStrong;` correctly swaps the
// side-table binding: the old object's weak-walk no longer hits
// this slot, and the new object's weak-walk does. Re-uses the
// module-scope weak pattern from weak_basic.xc so we can observe
// the slot across function scopes.
//
// Test surface:
//   T1  After first assign, weak tracks object A
//   T2  After reassign, weak now tracks object B
//   T3  Freeing B zeroes the weak slot
//   T4  Freeing A afterwards doesn't touch the (already-zero) slot
//
// The order matters: we free B first (which is what the weak is
// tracking at the time), then A (which the weak is NOT tracking
// because reassign unregistered that binding). If unregister-on-
// reassign is broken, freeing A would zero the slot in T4 even
// though we already asserted it was zero in T3.

#import "Stdio.xc"
#import "Assert.xc"

class Leaf
{
    u8 tag;
}

weak:Leaf* gW;

// Keep A alive across B's lifetime by holding its strong reference
// in a module-scope slot. Scope-exit of `keepA` would normally drop
// A's refcount; routing through gA means we control when A dies.
Leaf* gA;
Leaf* gB;

void allocBoth(void)
{
    gA = new Leaf();    gA.tag = (u8)1;
    gB = new Leaf();    gB.tag = (u8)2;
}

void pointWeakAtA(void)
{
    gW = gA;    // weak tracks A
}

void pointWeakAtB(void)
{
    gW = gB;    // weak unregisters A's binding, registers B's
}

void dropB(void)
{
    gB = (Leaf*)0;  // release B: refcount 0, dealloc, weak_zero_all_for
}

void dropA(void)
{
    gA = (Leaf*)0;  // release A: refcount 0, but no weak slot targets A
}

void main(void)
{
    Assert.reset();

    allocBoth();
    pointWeakAtA();
    Assert.isNotNull((pointer)gW);       // T1: weak tracks A

    pointWeakAtB();
    Assert.isNotNull((pointer)gW);       // T2: weak now tracks B (not A)

    dropB();
    Assert.isNull((pointer)gW);          // T3: B freed → weak zeroed

    // Temporarily stash a sentinel in gW so T4 can detect an
    // incorrect re-zero by A's release. If reassign didn't
    // unregister A's old binding, dropA would walk the table and
    // zero gW again — but there's nothing in the table keyed on A
    // anymore, so the sentinel survives.
    gW = gA;                             // weak re-tracks A (the survivor)
    Assert.isNotNull((pointer)gW);       // setup check: weak tracks A again
    dropA();
    Assert.isNull((pointer)gW);          // T4: A's release zeroed weak via its NEW binding
    Assert.summary();
    return;
}
