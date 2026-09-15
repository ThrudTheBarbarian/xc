// foundation_map_forin.xc — `for (Object@ k in m)` iterates a
// Map's keys via Enumerable's enumLength + enumAt protocol slots.
//
//   T1   for-in over a 3-entry map yields 3 keys (count matches).
//   T2   Sum of yielded keys' integer values matches the inserted
//        keys (ordering isn't guaranteed by Map but the multiset
//        of keys must round-trip).
//   T3   for-in over an empty map runs zero iterations.
//   T4   break inside the loop terminates early (count > 0).
//   T5   continue skips the body but keeps iterating.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── T1 + T2: 3-entry walk ──────────────────────────────────
    Map* m = new Map();
    m.set(Number.withU16((u16)10), Number.withU16((u16)100));
    m.set(Number.withU16((u16)20), Number.withU16((u16)200));
    m.set(Number.withU16((u16)30), Number.withU16((u16)300));

    u16 visits = (u16)0;
    u16 sum    = (u16)0;
    for (Object* o in m) {
        visits = visits + (u16)1;
        Number* k = (Number* ?)o;
        sum = sum + k.asU16();
    }
    Assert.isEqual(visits, (u16)3);                              // T1
    Assert.isEqual(sum, (u16)60);                                // T2 — 10+20+30

    // ── T3: empty map, zero iterations ─────────────────────────
    Map* empty = new Map();
    u16 emptyVisits = (u16)0;
    for (Object* o in empty) {
        emptyVisits = emptyVisits + (u16)1;
    }
    Assert.isEqual(emptyVisits, (u16)0);                         // T3

    // ── T4: break ──────────────────────────────────────────────
    u16 brokenVisits = (u16)0;
    for (Object* o in m) {
        brokenVisits = brokenVisits + (u16)1;
        if (brokenVisits == (u16)2) break;
    }
    Assert.isEqual(brokenVisits, (u16)2);                        // T4

    // ── T5: continue ───────────────────────────────────────────
    u16 contVisits = (u16)0;
    u16 contSum    = (u16)0;
    for (Object* o in m) {
        contVisits = contVisits + (u16)1;
        if ((contVisits & (u16)1) == (u16)1) continue;   // skip odd
        Number* k = (Number* ?)o;
        contSum = contSum + k.asU16();
    }
    Assert.isEqual(contVisits, (u16)3);                          // T5a
    // contSum receives only the 2nd visit's key (1 value).
    Assert.isTrue(contSum > (u16)0);                             // T5b

    Assert.summary();
    return;
}
