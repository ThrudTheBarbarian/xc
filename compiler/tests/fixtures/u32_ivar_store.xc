// u32_ivar_store.xc — bytes 3-4 of a u32 ivar must be stored.
//
// Pre-bug-fix: the ivar-store path in +ExprAssign.m's `width >= 3`
// branch was hardcoded to the 3-byte banked-pointer shape and only
// stored bytes 0/1/2. For a u32 ivar, bytes 2-3 (the high word held
// in u32HiReg) were never written, so any value > $FFFF was silently
// truncated on store. T1 catches it: $DEADBEEF stored, then read
// back, must round-trip.

#import "Stdio.xc"
#import "Assert.xc"

class Counter
{
    u32 v;
    void set(u32 x) { v = x; }
    u32  get(void)  { return v; }
}

void main(void)
{
    Assert.reset();
    Counter* c = new Counter();
    c.set((u32)$DEADBEEF);
    Assert.isEqual(c.get(), (u32)$DEADBEEF);   // T1: full 4-byte round-trip
    c.set((u32)600);
    Assert.isEqual(c.get(), (u32)600);          // T2: small value
    Assert.summary();
    return;
}
