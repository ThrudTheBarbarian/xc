// foundation_map_basic.xc — Map.xc set/get/remove/count, no
// resize, no ARC. Step 2 of the Map roll-out — verifies the
// open-addressing probe chain handles inserts, lookups,
// overwrites, and tombstone-aware removes. Step 3 layers ARC,
// step 4 layers resize, step 5 layers Enumerable.
//
//   T1   Empty map: count() == 0, isEmpty(), get(missing) == 0.
//   T2   set + get round-trip.
//   T3   set with multiple distinct keys; each round-trips.
//   T4   set on an existing key updates the value (count
//        unchanged).
//   T5   contains() distinguishes present vs missing keys.
//   T6   remove drops the entry; subsequent get returns 0.
//   T7   remove + re-set lands in the same slot (the tombstone
//        was reused) — verified indirectly by get returning the
//        new value.
//   T8   String keys round-trip alongside Number keys
//        (heterogeneous-key map).
//   T9   removeAll resets to empty.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── T1: empty map ────────────────────────────────────────────
    Map* m = new Map();
    Assert.isEqual(m.count(), (u16)0);                           // T1a
    Assert.isTrue(m.isEmpty());                                  // T1b
    Number* probe = Number.withI16(42);
    Object* miss = m.get(probe);
    Assert.isTrue(miss == (Object*)0);                           // T1c

    // ── T2: round-trip a single entry ────────────────────────────
    Number* k1 = Number.withI16(1);
    Number* v1 = Number.withI16(100);
    m.set(k1, v1);
    Assert.isEqual(m.count(), (u16)1);                           // T2a
    Number* got = (Number* ?)m.get(k1);
    Assert.isTrue(got != 0);
    Assert.isEqual(got.asI16(), (i16)100);                       // T2b

    // ── T3: multiple distinct keys ───────────────────────────────
    Number* k2 = Number.withI16(2);
    Number* k3 = Number.withI16(3);
    Number* v2 = Number.withI16(200);
    Number* v3 = Number.withI16(300);
    m.set(k2, v2);
    m.set(k3, v3);
    Assert.isEqual(m.count(), (u16)3);                           // T3a
    Number* g1 = (Number* ?)m.get(k1);
    Number* g2 = (Number* ?)m.get(k2);
    Number* g3 = (Number* ?)m.get(k3);
    Assert.isEqual(g1.asI16(), (i16)100);                        // T3b
    Assert.isEqual(g2.asI16(), (i16)200);                        // T3c
    Assert.isEqual(g3.asI16(), (i16)300);                        // T3d

    // ── T4: set on existing key updates value, count unchanged ───
    Number* v1b = Number.withI16(101);
    m.set(k1, v1b);
    Assert.isEqual(m.count(), (u16)3);                           // T4a
    Number* g1b = (Number* ?)m.get(k1);
    Assert.isEqual(g1b.asI16(), (i16)101);                       // T4b

    // ── T5: contains() ───────────────────────────────────────────
    Assert.isTrue(m.contains(k1));                               // T5a
    Number* kMiss = Number.withI16(999);
    Assert.isFalse(m.contains(kMiss));                           // T5b

    // ── T6: remove drops the entry ───────────────────────────────
    m.remove(k2);
    Assert.isEqual(m.count(), (u16)2);                           // T6a
    Object* gone = m.get(k2);
    Assert.isTrue(gone == (Object*)0);                           // T6b
    Assert.isFalse(m.contains(k2));                              // T6c

    // ── T7: remove + re-set (tombstone reuse) ────────────────────
    Number* v2b = Number.withI16(222);
    m.set(k2, v2b);
    Assert.isEqual(m.count(), (u16)3);                           // T7a
    Number* g2b = (Number* ?)m.get(k2);
    Assert.isEqual(g2b.asI16(), (i16)222);                       // T7b

    // ── T8: heterogeneous keys (String alongside Number) ─────────
    String* ks = String.withCString("hi");
    String* vs = String.withCString("there");
    m.set(ks, vs);
    Assert.isEqual(m.count(), (u16)4);                           // T8a
    Object* gs = m.get(ks);
    Assert.isTrue(gs != (Object*)0);                             // T8b
    String* gsTyped = (String* ?)gs;
    Assert.isTrue(gsTyped.equals(vs));                           // T8c

    // ── T9: removeAll ────────────────────────────────────────────
    m.removeAll();
    Assert.isEqual(m.count(), (u16)0);                           // T9a
    Assert.isTrue(m.isEmpty());                                  // T9b
    Assert.isFalse(m.contains(k1));                              // T9c

    Assert.summary();
    return;
}
