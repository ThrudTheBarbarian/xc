// foundation_map_resize.xc — Map.xc geometric resize at α > 0.75.
//
// v1 capped at 16 slots and inserts past 12 silently failed once
// _findSlot exhausted the table. This fixture exercises the
// auto-grow path through several doublings:
//
//   T1   13 inserts force one resize (16 → 32). Every key still
//        round-trips after the rehash.
//   T2   count == 13 across the resize boundary.
//   T3   Spot-check an entry inserted before the resize (key 0)
//        and one inserted after (key 12).
//   T4   Continue inserts to 50 entries — forces 32 → 64. Bulk
//        round-trip still resolves every key.
//   T5   remove half the entries, verify count, verify removed
//        keys disappear.
//   T6   Reinsert the removed keys with new values; old entries
//        and tombstones don't confuse the lookup.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    Map* m = new Map();

    // ── T1: 13 inserts (forces 16 → 32) ────────────────────────
    for (u16 i = (u16)0; i < (u16)13; i = i + (u16)1) {
        m.set(Number.withU16(i), Number.withU16(i + (u16)10000));
    }
    bool ok = true;
    for (u16 i = (u16)0; i < (u16)13; i = i + (u16)1) {
        Number* got = (Number* ?)m.get(Number.withU16(i));
        if (got == (Number*)0) ok = false;
        else if (got.asU16() != i + (u16)10000) ok = false;
    }
    Assert.isTrue(ok);                                           // T1
    Assert.isEqual(m.count(), (u16)13);                          // T2

    // ── T3: spot-check across the resize boundary ──────────────
    Number* pre = (Number* ?)m.get(Number.withU16((u16)0));
    Assert.isEqual(pre.asU16(), (u16)10000);                     // T3a
    Number* post = (Number* ?)m.get(Number.withU16((u16)12));
    Assert.isEqual(post.asU16(), (u16)10012);                    // T3b

    later(m);
    Assert.summary();
    return;
}

// The later phases live in their own function so the 6502 banker can place
// them in a code bank — main() plus the whole Foundation library is right at
// the unbanked-region ceiling on that target, and a monolithic main tips it
// over. (The production banked build is fine; this is the corpus's flatter
// in-process model.)
void later(Map* m)
{
    // ── T4: grow further to 50 (forces 32 → 64) ────────────────
    for (u16 i = (u16)13; i < (u16)50; i = i + (u16)1) {
        m.set(Number.withU16(i), Number.withU16(i + (u16)10000));
    }
    Assert.isEqual(m.count(), (u16)50);                          // T4a
    bool allOk = true;
    for (u16 i = (u16)0; i < (u16)50; i = i + (u16)1) {
        Number* got = (Number* ?)m.get(Number.withU16(i));
        if (got == (Number*)0) allOk = false;
        else if (got.asU16() != i + (u16)10000) allOk = false;
    }
    Assert.isTrue(allOk);                                        // T4b

    // ── T5: remove every even key ──────────────────────────────
    for (u16 i = (u16)0; i < (u16)50; i = i + (u16)2) {
        m.remove(Number.withU16(i));
    }
    Assert.isEqual(m.count(), (u16)25);                          // T5a
    Assert.isTrue(m.get(Number.withU16((u16)0))  == (Object*)0); // T5b
    Assert.isTrue(m.get(Number.withU16((u16)24)) == (Object*)0); // T5c
    // Odd keys still resolve.
    Number* odd13 = (Number* ?)m.get(Number.withU16((u16)13));
    Assert.isEqual(odd13.asU16(), (u16)10013);                   // T5d

    // ── T6: reinsert evens with new values ─────────────────────
    for (u16 i = (u16)0; i < (u16)50; i = i + (u16)2) {
        m.set(Number.withU16(i), Number.withU16(i + (u16)20000));
    }
    Assert.isEqual(m.count(), (u16)50);                          // T6a
    Number* ev4 = (Number* ?)m.get(Number.withU16((u16)4));
    Assert.isEqual(ev4.asU16(), (u16)20004);                     // T6b
    // Odds untouched.
    Number* odd5 = (Number* ?)m.get(Number.withU16((u16)5));
    Assert.isEqual(odd5.asU16(), (u16)10005);                    // T6c
    return;
}
