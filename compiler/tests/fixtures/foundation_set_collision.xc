// foundation_set_collision.xc — Set.xc linear-probe + resize
// behaviour under deliberate hash collisions.
//
// Mirror of foundation_map_collision but for Set's element-only
// slots. Values of the form k * 257 collide on Number.hash() (the
// XOR-fold of equal lo/hi bytes is zero), so every such element
// probes the same initial slot. The fixture inserts a long chain
// and rides it through the α > 0.75 resize trigger, verifying:
//
//   T1   30 colliding adds still report count() == 30 after the
//        16 → 32 → 64 doublings.
//   T2   Every added element is contained() — linear probing
//        placed them along successive slots; resize re-probed the
//        entire chain into the new (larger) table.
//   T3   Remove half the elements; remaining odd-indexed elements
//        still contain. Tombstones don't break the chain.
//   T4   Re-add the removed elements. Tombstone-aware probing
//        places them into the freed slots.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();
    Set* s = new Set();

    // ── T1: 30 colliding adds (forces 16 → 32 → 64) ────────────
    for (u16 k = (u16)0; k < (u16)30; k = k + (u16)1) {
        u16 key = k * (u16)257;
        s.add(Number.withU16(key));
    }
    Assert.isEqual(s.count(), (u16)30);                          // T1

    // ── T2: every added element is contained ───────────────────
    bool ok = true;
    for (u16 k = (u16)0; k < (u16)30; k = k + (u16)1) {
        u16 key = k * (u16)257;
        if (!s.contains(Number.withU16(key))) ok = false;
    }
    Assert.isTrue(ok);                                           // T2

    // ── T3: remove evens; odds still resolve through chain ─────
    for (u16 k = (u16)0; k < (u16)30; k = k + (u16)2) {
        u16 key = k * (u16)257;
        s.remove(Number.withU16(key));
    }
    Assert.isEqual(s.count(), (u16)15);                          // T3a
    bool oddsOk = true;
    for (u16 k = (u16)1; k < (u16)30; k = k + (u16)2) {
        u16 key = k * (u16)257;
        if (!s.contains(Number.withU16(key))) oddsOk = false;
    }
    Assert.isTrue(oddsOk);                                       // T3b

    // ── T4: re-add evens; tombstone reuse ─────────────────────
    for (u16 k = (u16)0; k < (u16)30; k = k + (u16)2) {
        u16 key = k * (u16)257;
        s.add(Number.withU16(key));
    }
    Assert.isEqual(s.count(), (u16)30);                          // T4a
    bool evensOk = true;
    for (u16 k = (u16)0; k < (u16)30; k = k + (u16)2) {
        u16 key = k * (u16)257;
        if (!s.contains(Number.withU16(key))) evensOk = false;
    }
    Assert.isTrue(evensOk);                                      // T4b

    Assert.summary();
    return;
}
