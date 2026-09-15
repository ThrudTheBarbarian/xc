// arc_ivar_reassign_new.xc — strong-ivar reassign with a `new T()` RHS
// must release the old value, not silently leak / mismatch refcounts.
//
// Pre-bug-fix the ARC ivar-reassign helper was gated on `!isBanked`,
// so banked-pointer ivars (`banked:T@`) fell through to the simple
// ivar-store path — which writes the new pointer into the slot but
// never reads the OLD value out, never decrefs / frees it.
// Reassigning `peer = new Tracker()` overwrote the slot with a fresh
// +1 reference and leaked the previous Tracker (its dealloc never
// fired and the heap block stayed allocated).
//
// T1: after the first install, no dealloc has run.
// T2: after replace overwrote peer with a new instance, the old
//     Tracker's dealloc must have fired exactly once.

#import "Stdio.xc"
#import "Assert.xc"

u16 deallocCount;

class Tracker
{
    u8 tag;
    void dealloc(void) { deallocCount = deallocCount + 1; }
}

class Holder
{
    banked:Tracker* peer;

    void install(void) :banked  { peer = new Tracker(); }
    void replace(void) :banked  { peer = new Tracker(); }
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;
    Holder* h = new Holder();
    h.install();
    Assert.isEqual(deallocCount, 0);   // T1
    h.replace();
    Assert.isEqual(deallocCount, 1);   // T2
    Assert.summary();
    return;
}
