// arc_multi_return.xc — ARC tuple-assign lowering for class-pointer
// multi-return functions (2b-multi-return in doc/ARC_roadmap.md).
//
// Surface:
//   T1  Initial tuple assign: both targets go from null → fresh +1
//       (dealloc counts unchanged at the call site; they'll fire at
//        main's scope exit)
//   T2  Reassignment via second tuple call: target's OLD pointer
//       must be released before the new +1 lands, so the dealloc
//       count bumps by two (one per dropped local)
//   T3  After main returns, every strong local has been released
//       exactly once (no double-free, no leak)
//
// Flat-heap only — banked-heap ARC is Phase 4 work.

#import "Stdio.xc"
#import "Assert.xc"

u16 deallocCount;

class Tracker
{
    u8 tag;
    void dealloc(void)
    {
        deallocCount = deallocCount + 1;
    }
}

Tracker*, Tracker* makePair(u8 tagA, u8 tagB)
{
    Tracker* a = new Tracker();
    a.tag = tagA;
    Tracker* b = new Tracker();
    b.tag = tagB;
    return a, b;
}

void main(void) : needsOS
{
    Assert.reset();
    deallocCount = 0;

    Tracker* x;
    Tracker* y;

    // ── T1: first assign — slots transition from null to owning ──
    (x, y) = makePair(1, 2);
    Assert.isEqual(x.tag, 1);                  // T1a
    Assert.isEqual(y.tag, 2);                  // T1b
    Assert.isEqual(deallocCount, 0);           // T1c — nothing freed yet

    // ── T2: second tuple assign overwrites both slots — old
    // pointers must be released before the new +1s land ──
    (x, y) = makePair(7, 9);
    Assert.isEqual(x.tag, 7);                  // T2a
    Assert.isEqual(y.tag, 9);                  // T2b
    Assert.isEqual(deallocCount, 2);           // T2c — the two old trackers

    // main's scope exit will release x and y.
    Assert.summary();
    return;
}
