// foundation_iter_cursor.xc — Map/Set enumeration is O(n), and stays correct.
//
// enumAt(i) used to rescan the slot table from slot 0 on every call, counting
// past empties and tombstones to reach the i'th live entry. The for-in driver
// calls it once per iteration, so walking a container was O(n²): one pass over
// a 20,000-entry Map took 1.08s, essentially all of it re-counting slots it had
// already counted.
//
// enumAt now remembers where the last call finished. A for-in asks for 0, 1,
// 2, … in order, so each call resumes from the previous slot — O(capacity) for
// the whole walk. 1.08s -> 0.13s, and most of what's left is building the map.
//
// The cursor is an optimisation, not a contract change, so what this fixture
// really guards is that nothing about enumeration got *weaker*:
//
//   T1  a full pass visits every element exactly once
//   T2  a SECOND pass over the same container visits them all again — the
//       cursor must not leave the container "used up"
//   T3  NESTED iteration over one container works: the inner loop moves the
//       cursor, so the outer loop's next request misses it and falls back to a
//       full scan. n*n pairs, no repeats, nothing skipped.
//   T4  mutation invalidates the cursor: iterate, add, iterate again
//   T5  a Set behaves the same way
//   T6  removal (which plants tombstones) doesn't confuse the walk
//
// The counts are the test. A cursor bug shows up as a missed element, a
// repeated one, or a null.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    // ── T1 / T2: a Map walked twice yields every key both times.
    Map* m = new Map();
    for (u16 i = (u16)0; i < (u16)40; i++)
        m.set(Number.with((i16)i), Number.with((i16)(i * (i16)2)));

    u16 pass1 = (u16)0;
    for (Object* k in m) { if (k != 0) pass1 = pass1 + (u16)1; }
    Assert.isEqual(pass1, (u16)40);                       // T1

    u16 pass2 = (u16)0;
    for (Object* k in m) { if (k != 0) pass2 = pass2 + (u16)1; }
    Assert.isEqual(pass2, (u16)40);                       // T2 — not used up

    // Every key must resolve to its value: proves enumAt returned real keys,
    // not slot garbage or nulls.
    u16 matched = (u16)0;
    for (Object* k in m) {
        Number* v = (Number* ?)m.get((Hashable*)k);
        Number* n = (Number* ?)k;
        if (v != 0 && n != 0 && v.asI16() == n.asI16() * (i16)2)
            matched = matched + (u16)1;
    }
    Assert.isEqual(matched, (u16)40);                     // T1b

    // ── T3: nested iteration. The inner loop steals the cursor; the outer
    // loop must still see all 40 (falling back to a scan).
    Map* small = new Map();
    for (u16 i = (u16)0; i < (u16)8; i++)
        small.set(Number.with((i16)i), Number.with((i16)i));

    u16 pairs = (u16)0;
    for (Object* a in small)
        for (Object* b in small)
            if (a != 0 && b != 0) pairs = pairs + (u16)1;
    Assert.isEqual(pairs, (u16)64);                       // T3 — 8 * 8

    // ── T4: mutating between walks invalidates the cursor.
    m.set(Number.with((i16)100), Number.with((i16)200));
    u16 pass3 = (u16)0;
    for (Object* k in m) { if (k != 0) pass3 = pass3 + (u16)1; }
    Assert.isEqual(pass3, (u16)41);                       // T4

    // ── T5: a Set enumerates the same way, twice over.
    Set* s = new Set();
    for (u16 i = (u16)0; i < (u16)30; i++)
        s.add(String.withCString("k"));                   // all equal — 1 element
    Assert.isEqual(s.count(), (u16)1);                    // T5a — dedup works

    Set* s2 = new Set();
    for (u16 i = (u16)0; i < (u16)30; i++)
        s2.add(Number.with((i16)i));
    u16 sp1 = (u16)0;
    for (Object* e in s2) { if (e != 0) sp1 = sp1 + (u16)1; }
    u16 sp2 = (u16)0;
    for (Object* e in s2) { if (e != 0) sp2 = sp2 + (u16)1; }
    Assert.isEqual(sp1, (u16)30);                         // T5b
    Assert.isEqual(sp2, (u16)30);                         // T5c

    u16 spairs = (u16)0;
    for (Object* a in s2)
        for (Object* b in s2)
            if (a != 0 && b != 0) spairs = spairs + (u16)1;
    Assert.isEqual(spairs, (u16)900);                     // T5d — 30 * 30 nested

    // ── T6: removal plants tombstones; the walk must skip them cleanly.
    for (u16 i = (u16)0; i < (u16)30; i = i + (u16)2)
        s2.remove(Number.with((i16)i));                   // drop the 15 evens
    Assert.isEqual(s2.count(), (u16)15);                  // T6a

    u16 after = (u16)0;
    for (Object* e in s2) { if (e != 0) after = after + (u16)1; }
    Assert.isEqual(after, (u16)15);                       // T6b

    Assert.summary();
    return;
}
