// arc_self_retain.xc — ARC phase 2d self-pointer retain coverage.
//
// Under callee-retains-params a method should retain `self` on
// entry and release at scope exit. This only applies when every
// known call site is a heap receiver — a stack-instance receiver
// would touch non-heap bytes if we tried to retain. Sema's
// hasHeapReceiver / hasNonHeapReceiver bits gate the prologue
// emit.
//
// Test surface:
//   T1  Method entry retains self → inside the method, the caller
//       can drop its only reference to the receiver without the
//       receiver's dealloc firing mid-body.
//   T2  When the method returns, scope-exit cleanup drops the
//       retained self → dealloc fires exactly once in total.
//   T3  A method on a stack receiver does NOT retain self
//       (otherwise we'd decref a non-heap address — corruption).
//       Test: stack instance method call round-trips values and
//       lives through main without tripping.
//
// Flat-heap only — banked-heap ARC is Phase 4.

#import "Stdio.xc"
#import "Assert.xc"

u16 deallocCount;
u16 midCount;
u16 released;     // set inside the method to trigger a release

class Tracker
{
    u8 tag;

    void dealloc(void)
    {
        deallocCount = deallocCount + 1;
    }

    // Called on a heap receiver. We signal `release_holder()` (a
    // free function, not `self.x()`) to drop the global reference
    // that was the only holder of us — if self-retain fires,
    // midCount stays 0 across the release. Otherwise dealloc would
    // run immediately and midCount == 1.
    void observeSelfAlive(void)
    {
        release_holder();
        midCount = deallocCount;
    }
}

// Stack-only class: every call site is a bare stack local. Sema
// must NOT set hasHeapReceiver, so the prologue retain is skipped.
// If 2d miscompiled this, _obj_retain would touch bytes before
// the stack instance → silent corruption.
class StackOnly
{
    u8 v;
    u8 mark;

    void setBoth(u8 a, u8 b)
    {
        v = a;
        mark = b;
    }
}

Tracker* holder;

void release_holder(void)
{
    // Drop the global's reference. Under Phase 2b assignment
    // lowering this decrefs the block holder points at — if
    // refcount had been 1 (no self-retain), dealloc fires now.
    holder = (Tracker*)0;
    released = 1;
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;
    midCount     = $FF;
    released     = 0;

    // ── Heap receiver path (2d exercised) ──────────────────
    holder = new Tracker();
    holder.tag = 1;

    // Method call. Prologue retains self (refcount 1 → 2).
    // Inside, release_holder() drops holder (refcount 2 → 1),
    // midCount reads deallocCount which must still be 0.
    // Method exits, scope-exit releases self (refcount 1 → 0),
    // dealloc fires exactly once.
    holder.observeSelfAlive();

    Assert.isEqual(released, 1);        // T1a — release_holder ran
    Assert.isEqual(midCount, 0);        // T1  — self stayed alive mid-body
    Assert.isEqual(deallocCount, 1);    // T2  — dealloc fired at exit

    // ── Stack receiver path (2d skipped) ──────────────────
    // If self-retain wrongly emitted here, _obj_retain on the
    // stack instance's address would touch arbitrary ZP bytes
    // and the readback would corrupt.
    StackOnly s;
    s.setBoth(33, 77);
    Assert.isEqual(s.v, 33);            // T3a
    Assert.isEqual(s.mark, 77);         // T3b

    Assert.summary();
    return;
}
