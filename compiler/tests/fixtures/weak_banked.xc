// weak_banked.xc — scalar weak variable on banked-heap targets.
//
// Validates Phase 3 PR 5: the side-table key widens from 2 bytes
// (obj lo/hi) to 3 bytes (obj lo/hi + bank) so a freed heap block
// in one bank doesn't collide with a live block at the same 16-bit
// address in another bank. Mirrors weak_basic.xc's flow but runs
// on xt-heap / xe-heap where class pointers default to Banked
// placement and classes can live across multiple heap pages.
//
// Test surface:
//   T1  weak global tracks the strong local while alive
//   T2  freeing the strong zeroes the weak slot via the 3-byte key
//       + per-entry bank byte path through _weak_zero_all_for
//
// Module-scope weak global so its lifetime outlives the helper's
// strong local scope. On xt-heap / xe-heap bare `weak:Leaf@` parses
// as weak + placement=Banked(default), which PR 5's sema + codegen
// accept for locals/globals.

#import "Stdio.xc"
#import "Assert.xc"

class Leaf
{
    u8 tag;
}

weak:Leaf* gW;

void fillAndDrop(void)
{
    Leaf* s = new Leaf();          // banked strong local, 3-byte
    s.tag = (u8)99;
    gW = s;                         // weak assign, registers 3-byte key
    Assert.isNotNull((pointer)gW);  // T1: weak tracks the banked allocation
    // Scope exit: s releases → refcount 0 → _weak_zero_all_for
    // walks the side table and zeroes gW's 3-byte slot via the
    // parallel bank table lookup.
}

void main(void)
{
    Assert.reset();
    fillAndDrop();
    Assert.isNull((pointer)gW);     // T2: auto-zero via 3-byte key match
    Assert.summary();
    return;
}
