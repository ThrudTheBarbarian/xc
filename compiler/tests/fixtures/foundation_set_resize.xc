// foundation_set_resize.xc — Set.xc geometric resize at α > 0.75.
//
// Mirror of foundation_map_resize but for Set's element-only
// slots. Exercises the auto-grow path through several doublings:
//
//   T1   13 adds force one resize (16 → 32). Every element is
//        still contained() after the rehash.
//   T2   count == 13 across the resize boundary.
//   T3   Spot-check an element added before the resize (key 0) and
//        one added after (key 12).
//   T4   Continue adds to 50 entries — forces 32 → 64. Bulk
//        contains() still resolves every element.
//   T5   remove half the entries, verify count, verify removed
//        elements disappear.
//   T6   Re-add the removed elements; old entries and tombstones
//        don't confuse the probe.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    Set* s = new Set();

    // ── T1: 13 adds (forces 16 → 32) ───────────────────────────
    for (u16 i = (u16)0; i < (u16)13; i = i + (u16)1) {
        s.add(Number.withU16(i));
    }
    bool ok = true;
    for (u16 i = (u16)0; i < (u16)13; i = i + (u16)1) {
        if (!s.contains(Number.withU16(i))) ok = false;
    }
    Assert.isTrue(ok);                                           // T1
    Assert.isEqual(s.count(), (u16)13);                          // T2

    // ── T3: spot-check across the resize boundary ─────────────
    Assert.isTrue(s.contains(Number.withU16((u16)0)));           // T3a
    Assert.isTrue(s.contains(Number.withU16((u16)12)));          // T3b

    // ── T4: grow further to 50 (forces 32 → 64) ───────────────
    for (u16 i = (u16)13; i < (u16)50; i = i + (u16)1) {
        s.add(Number.withU16(i));
    }
    Assert.isEqual(s.count(), (u16)50);                          // T4a
    bool allOk = true;
    for (u16 i = (u16)0; i < (u16)50; i = i + (u16)1) {
        if (!s.contains(Number.withU16(i))) allOk = false;
    }
    Assert.isTrue(allOk);                                        // T4b

    // ── T5: remove every even element ─────────────────────────
    for (u16 i = (u16)0; i < (u16)50; i = i + (u16)2) {
        s.remove(Number.withU16(i));
    }
    Assert.isEqual(s.count(), (u16)25);                          // T5a
    Assert.isFalse(s.contains(Number.withU16((u16)0)));          // T5b
    Assert.isFalse(s.contains(Number.withU16((u16)24)));         // T5c
    // Odd elements still resolve.
    Assert.isTrue(s.contains(Number.withU16((u16)13)));          // T5d

    // ── T6: re-add evens ─────────────────────────────────────
    for (u16 i = (u16)0; i < (u16)50; i = i + (u16)2) {
        s.add(Number.withU16(i));
    }
    Assert.isEqual(s.count(), (u16)50);                          // T6a
    Assert.isTrue(s.contains(Number.withU16((u16)4)));           // T6b
    // Odds untouched.
    Assert.isTrue(s.contains(Number.withU16((u16)5)));           // T6c

    Assert.summary();
    return;
}
