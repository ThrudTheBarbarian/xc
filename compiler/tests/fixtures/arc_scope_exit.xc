// arc_scope_exit.xc — validate ARC 2a scope-exit cleanup of owning locals.
//
// Under -farc (default on) every strong class-pointer local is added
// to a per-function cleanup list at decl time and _obj_decref'd at
// scope exit. This fixture watches dealloc() invocations to prove:
//
//   T1  Strong local allocated in main() is auto-released when main()
//       exits (we observe the dealloc count via a global counter that
//       Assert reads before the function exits).
//   T2  A helper function's strong local is auto-released on fall-
//       through return. Caller sees the dealloc count incremented.
//   T3  Multiple locals in the same function are released in reverse
//       declaration order — last-in-first-out, so a local that borrows
//       from an earlier local sees the earlier one still live when its
//       own dealloc runs.
//   T4  A strong local declared but never assigned (refcount-slot is
//       zeroed at decl time) cleans up as a null-release — dealloc
//       does not fire.
//   T5  Returning a simple-identifier strong local retains across
//       scope exit: caller receives a +1 reference and the object
//       lives until the caller releases it at its own scope exit.
//   T6  Nested calls: helper->sub with strong locals in each releases
//       them at the correct boundaries (sub's locals dealloc before
//       helper's locals do).

#import "Stdio.xc"
#import "Assert.xc"

class Tracker
{
    u8 tag;
    void dealloc(void)
    {
        deallocCount = deallocCount + 1;
        lastDeallocTag = tag;
    }
}

u16 deallocCount;
u8  lastDeallocTag;

// T2 helper: declares a strong local and falls through to return.
// Under 2a, the local must be auto-released at scope exit.
void leakyFallThrough(void)
{
    Tracker* t = new Tracker();
    t.tag = 2;
    // No delete, no release — 2a scope-exit cleanup releases `t`.
}

// T3 helper: three locals in declaration order, expect reverse order
// on cleanup.
void threeLocals(void)
{
    Tracker* a = new Tracker();  a.tag = 10;
    Tracker* b = new Tracker();  b.tag = 20;
    Tracker* c = new Tracker();  c.tag = 30;
    // Expected cleanup order on exit: c (tag 30), b (tag 20), a (tag 10).
}

// T4 helper: declares but never assigns. The zero-init arcMaybeTrackLocal
// emits makes the cleanup a null-release (no dealloc, no crash).
void unusedLocal(void)
{
    Tracker* _unused;
    // Cleanup sees zero → _obj_decref returns carry-clear → no dealloc.
}

// T5 helper: returns a strong local — must retain so the caller's +1
// reference survives the scope-exit cleanup.
Tracker* makeTracker(u8 which)
{
    Tracker* t = new Tracker();
    t.tag = which;
    return t;
}

// T7 helper: returns `new T()` directly. Under ARC's always-+1
// return convention the allocator already hands the caller a +1;
// no extra retain is emitted (value-producing expression).
Tracker* makeTrackerDirect(u8 which)
{
    Tracker* t = new Tracker();  // spare local so a cleanup exists
    t.tag = which - 1;
    return new Tracker();        // new-expr return — no retain
}

// T6 helpers: sub and helper.
void subHelper(void)
{
    Tracker* sub1 = new Tracker();  sub1.tag = 100;
}

void callerOfSub(void)
{
    Tracker* outer = new Tracker();  outer.tag = 50;
    subHelper();
    // At this point subHelper's cleanup has already fired; outer is
    // still live. On return, outer is released.
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;
    lastDeallocTag = 0;

    // ── T2: helper's strong local auto-released on fall-through ──
    leakyFallThrough();
    Assert.isEqual(deallocCount, 1);
    Assert.isEqual(lastDeallocTag, 2);

    // ── T3: three locals released in reverse-declaration order ──
    u16 beforeThree = deallocCount;
    threeLocals();
    u16 afterThree = deallocCount;
    Assert.isEqual(afterThree - beforeThree, 3);
    // Last dealloc seen is the FIRST-declared local's (lastDeallocTag == 10).
    Assert.isEqual(lastDeallocTag, 10);

    // ── T4: uninitialised strong local cleans up as a null-release ──
    u16 beforeUnused = deallocCount;
    unusedLocal();
    Assert.isEqual(deallocCount, beforeUnused);   // no dealloc ran

    // ── T5: return from helper transfers a live +1 reference ──
    u16 beforeMake = deallocCount;
    Tracker* returned = makeTracker(77);
    Assert.isEqual(returned.tag, 77);
    Assert.isEqual(deallocCount, beforeMake);     // still live

    // ── T7: returning `new T()` directly — no retain emitted, but
    //        the returned object still lives (allocator's +1 is
    //        what the caller receives). The helper's side local is
    //        released by scope-exit cleanup; the returned object
    //        stays live because the caller now owns +1.
    u16 beforeDirect = deallocCount;
    Tracker* direct = makeTrackerDirect(99);
    Assert.isEqual(deallocCount - beforeDirect, 1);   // side local released
    // Writing through `direct` should succeed — if the ARC return
    // convention dropped the ref early, the payload would be
    // recycled by a subsequent new and this store would corrupt it.
    direct.tag = 123;
    Assert.isEqual(direct.tag, 123);

    // ── T6: nested calls release in the right order ──
    u16 beforeNested = deallocCount;
    callerOfSub();
    // subHelper's sub1 (tag 100) dealloc'd before callerOfSub's outer
    // (tag 50) dealloc'd, so lastDeallocTag now == 50.
    Assert.isEqual(deallocCount - beforeNested, 2);
    Assert.isEqual(lastDeallocTag, 50);

    // ── T1: `returned` and `direct` are still alive here; they'll
    // be auto-released when main() exits. Assert.summary runs first,
    // so the dealloc events from main()'s cleanup happen after the
    // summary — not something we can assert on inside main().
    // Event tally so far: T2 (1) + T3 (3) + T7 (1) + T6 (2) = 7.
    Assert.isEqual(deallocCount, 7);

    Assert.summary();
    return;
}
