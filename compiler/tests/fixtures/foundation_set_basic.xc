// foundation_set_basic.xc — Set.xc add/contains/remove/count, no
// ARC focus. Verifies the open-addressing probe chain handles
// inserts, membership checks, dedup-on-readd, tombstone-aware
// removes, and removeAll.
//
//   T1   Empty set: count() == 0, isEmpty(), contains(missing) false.
//   T2   add + contains round-trip.
//   T3   add with multiple distinct elements; each is contained;
//        count tracks.
//   T4   add of an existing element is a no-op (count unchanged,
//        still contained).
//   T5   contains() distinguishes present vs missing.
//   T6   remove drops the entry; subsequent contains() false.
//   T7   remove + re-add reuses the tombstone (verified indirectly
//        by contains returning true post-readd, count tracking).
//   T8   Heterogeneous element types (String alongside Number) live
//        in the same set without colliding.
//   T9   removeAll resets to empty.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── T1: empty set ────────────────────────────────────────────
    Set* s = new Set();
    Assert.isEqual(s.count(), (u16)0);                           // T1a
    Assert.isTrue(s.isEmpty());                                  // T1b
    Number* probe = Number.withI16(42);
    Assert.isFalse(s.contains(probe));                           // T1c

    // ── T2: round-trip a single element ──────────────────────────
    Number* e1 = Number.withI16(1);
    s.add(e1);
    Assert.isEqual(s.count(), (u16)1);                           // T2a
    Assert.isTrue(s.contains(e1));                               // T2b

    // ── T3: multiple distinct elements ───────────────────────────
    Number* e2 = Number.withI16(2);
    Number* e3 = Number.withI16(3);
    s.add(e2);
    s.add(e3);
    Assert.isEqual(s.count(), (u16)3);                           // T3a
    Assert.isTrue(s.contains(e1));                               // T3b
    Assert.isTrue(s.contains(e2));                               // T3c
    Assert.isTrue(s.contains(e3));                               // T3d

    // ── T4: re-add of an existing element is a no-op ─────────────
    Number* e1again = Number.withI16(1);   // same value, distinct heap obj
    s.add(e1again);
    Assert.isEqual(s.count(), (u16)3);                           // T4a — count unchanged
    Assert.isTrue(s.contains(e1again));                          // T4b

    // ── T5: contains() distinguishes present vs missing ──────────
    Number* kMiss = Number.withI16(999);
    Assert.isFalse(s.contains(kMiss));                           // T5

    // ── T6: remove drops the entry ───────────────────────────────
    s.remove(e2);
    Assert.isEqual(s.count(), (u16)2);                           // T6a
    Assert.isFalse(s.contains(e2));                              // T6b

    // ── T7: remove + re-add (tombstone reuse) ────────────────────
    Number* e2b = Number.withI16(2);
    s.add(e2b);
    Assert.isEqual(s.count(), (u16)3);                           // T7a
    Assert.isTrue(s.contains(e2b));                              // T7b

    // ── T8: heterogeneous element types ──────────────────────────
    String* word = String.withCString("hello");
    s.add(word);
    Assert.isEqual(s.count(), (u16)4);                           // T8a
    Assert.isTrue(s.contains(word));                             // T8b
    String* wordCopy = String.withCString("hello");
    Assert.isTrue(s.contains(wordCopy));                         // T8c — equal-by-value

    // ── T9: removeAll ────────────────────────────────────────────
    s.removeAll();
    Assert.isEqual(s.count(), (u16)0);                           // T9a
    Assert.isTrue(s.isEmpty());                                  // T9b
    Assert.isFalse(s.contains(e1));                              // T9c

    Assert.summary();
    return;
}
