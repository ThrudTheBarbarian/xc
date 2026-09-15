// foundation_map_collision.xc — Map.xc linear-probe + resize
// behaviour under deliberate hash collisions.
//
// Number.hash() XOR-folds the i32 bytes. For values of the form
// k * 257 (= k | (k << 8), k ∈ [0, 255]), the low and high bytes
// are equal, so the XOR folds to zero — every such key probes the
// same initial slot. The fixture inserts a long collision chain
// and rides it through the α > 0.75 resize trigger, verifying
// that:
//   T1   30 colliding keys still report count() == 30 after the
//        16 → 32 → 64 doublings demanded by the load factor.
//   T2   Every inserted key round-trips. Linear probing places
//        them along successive slots; resize re-probes the entire
//        chain into the new (larger) table.
//   T3   remove half the keys; remaining odd-indexed keys still
//        resolve. Tombstones don't break the chain.
//   T4   Reinsert the removed keys with new values. Tombstone-
//        aware probing places them into the freed slots.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();
    Map* m = new Map();

    // ── T1: 30 colliding inserts (forces 16 → 32 → 64) ─────────
    for (u16 k = (u16)0; k < (u16)30; k = k + (u16)1) {
        u16 key = k * (u16)257;
        u16 val = k + (u16)1000;
        m.set(Number.withU16(key), Number.withU16(val));
    }
    Assert.isEqual(m.count(), (u16)30);                          // T1

    // ── T2: every inserted key round-trips ─────────────────────
    bool ok = true;
    for (u16 k = (u16)0; k < (u16)30; k = k + (u16)1) {
        u16 key = k * (u16)257;
        u16 expected = k + (u16)1000;
        Number* got = (Number* ?)m.get(Number.withU16(key));
        if (got == (Number*)0) ok = false;
        else if (got.asU16() != expected) ok = false;
    }
    Assert.isTrue(ok);                                           // T2

    // ── T3: remove evens; odds still resolve through the chain ─
    for (u16 k = (u16)0; k < (u16)30; k = k + (u16)2) {
        u16 key = k * (u16)257;
        m.remove(Number.withU16(key));
    }
    Assert.isEqual(m.count(), (u16)15);                          // T3a
    bool oddsOk = true;
    for (u16 k = (u16)1; k < (u16)30; k = k + (u16)2) {
        u16 key = k * (u16)257;
        u16 expected = k + (u16)1000;
        Number* got = (Number* ?)m.get(Number.withU16(key));
        if (got == (Number*)0) oddsOk = false;
        else if (got.asU16() != expected) oddsOk = false;
    }
    Assert.isTrue(oddsOk);                                       // T3b

    // ── T4: reinsert evens with new values; tombstone reuse ────
    for (u16 k = (u16)0; k < (u16)30; k = k + (u16)2) {
        u16 key = k * (u16)257;
        u16 val = k + (u16)2000;
        m.set(Number.withU16(key), Number.withU16(val));
    }
    Assert.isEqual(m.count(), (u16)30);                          // T4a
    bool evensOk = true;
    for (u16 k = (u16)0; k < (u16)30; k = k + (u16)2) {
        u16 key = k * (u16)257;
        u16 expected = k + (u16)2000;
        Number* got = (Number* ?)m.get(Number.withU16(key));
        if (got == (Number*)0) evensOk = false;
        else if (got.asU16() != expected) evensOk = false;
    }
    Assert.isTrue(evensOk);                                      // T4b

    Assert.summary();
    return;
}
