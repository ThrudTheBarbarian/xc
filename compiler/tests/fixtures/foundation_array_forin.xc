// foundation_array_forin.xc — `for (Object@ e in arr)` dispatches
// through the Enumerable protocol's vtable slots so the body sees
// each element from a class-instance collection.
//
//   T1   for-in over a 3-element Array yields the three Numbers
//        in order, downcast to a typed Number@ inside the body.
//   T2   loop count matches enumLength() — sentinel before/after.
//   T3   `break` inside the body exits early.
//   T4   `continue` skips the rest of the body.
//   T5   nested for-in over the same Array (stateless dispatch
//        through enumAt(i)) — outer × inner element pairs all
//        visited.
//
// Heap-capable targets only — Array is heap-allocated.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    Array* a = new Array();
    a.add(Number.withU16((u16)10));
    a.add(Number.withU16((u16)20));
    a.add(Number.withU16((u16)30));

    // ── T1 + T2: every element visited, in order ─────────────────
    u16 sum = (u16)0;
    u16 visits = (u16)0;
    for (Object* o in a) {
        Number* n = (Number* ?)o;
        if (n != 0) {
            sum    = sum    + n.asU16();
            visits = visits + (u16)1;
        }
    }
    Assert.isEqual(sum,    (u16)60);                             // T1
    Assert.isEqual(visits, (u16)3);                              // T2

    // ── T3: break exits early ────────────────────────────────────
    u16 brkVisits = (u16)0;
    for (Object* o in a) {
        brkVisits = brkVisits + (u16)1;
        if (brkVisits == (u16)2) break;
    }
    Assert.isEqual(brkVisits, (u16)2);                           // T3

    // ── T4: continue skips the rest of the body ──────────────────
    u16 contSum = (u16)0;
    u16 contIdx = (u16)0;
    for (Object* o in a) {
        contIdx = contIdx + (u16)1;
        if (contIdx == (u16)2) continue;
        Number* n = (Number* ?)o;
        if (n != 0) contSum = contSum + n.asU16();
    }
    Assert.isEqual(contSum, (u16)40);                            // T4 — 10 + 30

    // ── T5: nested for-in over the same Array ────────────────────
    u16 pairs = (u16)0;
    for (Object* outer in a) {
        for (Object* inner in a) {
            pairs = pairs + (u16)1;
        }
    }
    Assert.isEqual(pairs, (u16)9);                               // T5 — 3 × 3

    Assert.summary();
    return;
}
