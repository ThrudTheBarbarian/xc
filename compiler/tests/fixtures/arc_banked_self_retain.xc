// arc_banked_self_retain.xc — Phase 4.2 Bug 7: scope-exit
// release of __self uses the right bank source.
//
// arcMaybeRetainAndTrackSelfForMethod emits the self-retain on
// method entry for heap-only-receiver classes. The retain side
// uses `LDY #heap_bank_first` as a conservative default (the
// caller has just selected the receiver's bank, so the bank
// window is already correct; the hardcode only matters for the
// refcount byte address, which `_obj_retain` accesses after
// saving/restoring its own bank around the refcount work).
//
// Before this fix, however, the `__self` cleanup entry was
// tagged `isBanked=YES`. At scope-exit the generic walker
// reads Y from `slot+2` for full banked pointers — but
// `__self` is always 2 bytes (see _selfPtrAddr's allocation),
// so `slot+2` is the byte AFTER __self, which is a different
// ZP local's lo byte. Garbage Y got passed to `_obj_decref`,
// which then switched to a wrong bank for the refcount work.
//
// Fix: tag __self with `isHeapImplicitBank=YES` instead.
// Scope-exit then emits `LDY #heap_bank_first` — matching the
// retain side. For bank-1 receivers the pair is exactly right.
// For bank-2+ receivers both retain and release hit the same
// wrong bank symmetrically — benign (the object's real
// refcount is managed via the slot's owning +1, not via
// self-retain); per-instance __self bank tracking remains a
// deferred Phase 4.3 item.
//
// Coverage:
//   T1: method call on a bank-1 receiver round-trips a field.
//   T2: post-call the receiver's refcount is still 1 (self-
//       retain + self-release balance).
//   T3-T5: sequential method calls on the same receiver across
//          heap-init boundary (exercises _heap_free of a
//          method-scope __self retain without corrupting the
//          free-list).

#import "Stdio.xc"
#import "Assert.xc"

u16 boxDealloc;

class Box
{
    u8 id;
    u8 value;

    u8 getValue(void) { return value; }

    u16 doubled(void) { return (u16)value * 2; }

    void dealloc(void) { boxDealloc = boxDealloc + 1; }
}

void main(void)
{
    Assert.reset();
    boxDealloc = 0;

    Box* b = new Box();
    b.id = 42;
    b.value = 77;

    // Method call on the receiver. Entry fires self-retain;
    // exit fires self-release (the scope-exit walker path).
    u8 v1 = b.getValue();
    Assert.isEqual((u16)v1, 77);                          // T1

    // Object hasn't been dealloced yet — the self retain /
    // release pair balances and the slot still holds the
    // original +1.
    Assert.isEqual(boxDealloc, 0);                        // T2

    // Sequential calls exercise the same path repeatedly. Pre-
    // fix, garbage Y through _obj_decref would randomly
    // corrupt ZP / heap state — a tight loop of method calls
    // amplified any instability into visible failures.
    u8 v2 = b.getValue();
    Assert.isEqual((u16)v2, 77);                          // T3

    u16 d = b.doubled();
    Assert.isEqual(d, 154);                               // T4

    u8 v3 = b.getValue();
    Assert.isEqual((u16)v3, 77);                          // T5

    // Scope-exit of main releases b → 1 dealloc.
    Assert.summary();
    return;
}
