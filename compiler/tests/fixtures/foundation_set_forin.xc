// foundation_set_forin.xc — `for (Object@ e in s)` iterates a
// Set's elements via Enumerable's enumLength + enumAt protocol
// slots.
//
//   T1   for-in over a 3-element set yields 3 elements (count
//        matches).
//   T2   Sum of yielded elements' integer values matches the
//        inserted set (ordering isn't guaranteed by Set's open-
//        addressing layout but the multiset of elements must round-
//        trip).
//   T3   for-in over an empty set runs zero iterations.
//   T4   break inside the loop terminates early.
//   T5   continue skips the body but keeps iterating.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── T1 + T2: 3-element walk ────────────────────────────────
    Set* s = new Set();
    s.add(Number.withU16((u16)10));
    s.add(Number.withU16((u16)20));
    s.add(Number.withU16((u16)30));

    u16 visits = (u16)0;
    u16 sum    = (u16)0;
    for (Object* o in s) {
        visits = visits + (u16)1;
        Number* e = (Number* ?)o;
        sum = sum + e.asU16();
    }
    Assert.isEqual(visits, (u16)3);                              // T1
    Assert.isEqual(sum, (u16)60);                                // T2 — 10+20+30

    // ── T3: empty set, zero iterations ─────────────────────────
    Set* empty = new Set();
    u16 emptyVisits = (u16)0;
    for (Object* o in empty) {
        emptyVisits = emptyVisits + (u16)1;
    }
    Assert.isEqual(emptyVisits, (u16)0);                         // T3

    // ── T4: break ──────────────────────────────────────────────
    u16 brokenVisits = (u16)0;
    for (Object* o in s) {
        brokenVisits = brokenVisits + (u16)1;
        if (brokenVisits == (u16)2) break;
    }
    Assert.isEqual(brokenVisits, (u16)2);                        // T4

    // ── T5: continue ───────────────────────────────────────────
    u16 contVisits = (u16)0;
    u16 contSum    = (u16)0;
    for (Object* o in s) {
        contVisits = contVisits + (u16)1;
        if ((contVisits & (u16)1) == (u16)1) continue;   // skip odd
        Number* e = (Number* ?)o;
        contSum = contSum + e.asU16();
    }
    Assert.isEqual(contVisits, (u16)3);                          // T5a
    Assert.isTrue(contSum > (u16)0);                             // T5b

    Assert.summary();
    return;
}
