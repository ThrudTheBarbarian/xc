// arc_forin_early_return.xc — a for-in loop variable is BORROWED. Returning
// from inside the loop must not release it.
//
// The element belongs to the container being walked; the loop is only looking
// at it. But the loop variable was registered as a strong local, so a `return`
// from inside the loop body walked the ARC scopes with the binding still live
// and dropped a refcount on an element the container still owned.
//
// The normal exit path never showed it: by the time the enclosing scope was
// popped, the loop variable's binding was gone and the release was skipped. So
// the bug fired ONLY when you returned early — which is to say, only in the
// plainest shape there is:
//
//     for (Object@ o in items) { if (match(o)) return true; }        // a search
//
// Every linear search over a container dropped a refcount on the element it
// found. Set.intersects and Set.isSubsetOf are written exactly that way, which
// is how it surfaced: a Set freed out from under itself after a few queries and
// then faulted in _findSlot with a null table — far from the cause, as usual.
//
//   T1  a full for-in releases nothing (it never did — the control)
//   T2  a for-in with an early return releases nothing either
//   T3  the elements survive many searches, and the container is intact
//   T4  `break` out of a for-in is the same shape and must also be clean
//   T5  the search still WORKS — this is not a fix that stops iterating
//   T6  a for-in over a Map / Set (the class-Enumerable path, not just Array)
//   T7  nested for-in with an inner early return

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

u16 gGone = (u16)0;

class Item
{
    u16 v;
    void init(void)    { v = (u16)0; }
    void dealloc(void) { gGone = gGone + (u16)1; }
}

// T1: runs to completion.
u16 countAll(Array* a)
{
    u16 n = (u16)0;
    for (Object* o in a) { if (o != 0) n = n + (u16)1; }
    return n;
}

// T2: returns from inside the loop — the shape that broke.
bool findValue(Array* a, u16 want)
{
    for (Object* o in a) {
        Item* it = (Item* ?)o;
        if (it != 0 && it.v == want) return true;
    }
    return false;
}

// T4: breaks out of the loop instead of returning.
u16 firstMatch(Array* a, u16 want)
{
    u16 found = (u16)$FFFF;
    for (Object* o in a) {
        Item* it = (Item* ?)o;
        if (it != 0 && it.v == want) { found = it.v; break; }
    }
    return found;
}

// T6: the class-Enumerable path — a Set, not an Array.
bool setHas(Set* s, i16 want)
{
    for (Object* o in s) {
        Number* n = (Number* ?)o;
        if (n != 0 && n.asI16() == want) return true;
    }
    return false;
}

// T7: nested, with the inner loop returning early.
bool anyPair(Array* a)
{
    for (Object* x in a) {
        for (Object* y in a) {
            Item* ix = (Item* ?)x;
            Item* iy = (Item* ?)y;
            if (ix != 0 && iy != 0 && ix.v + iy.v == (u16)7) return true;
        }
    }
    return false;
}

void main(void)
{
    Array* a = new Array();
    for (u16 i = (u16)0; i < (u16)4; i++) {
        Item* it = new Item();
        it.v = i + (u16)1;              // 1,2,3,4
        a.add(it);
    }
    gGone = (u16)0;

    // ── T1: the control. A full walk owes nothing.
    for (u16 i = (u16)0; i < (u16)10; i++) {
        u16 n = countAll(a);
        Assert.isEqual(n, (u16)4);
    }
    Assert.isEqual(gGone, (u16)0);                        // T1

    // ── T2 / T5: an early-returning search, many times over. It must find what
    // it is looking for AND owe nothing.
    for (u16 i = (u16)0; i < (u16)10; i++) {
        Assert.isTrue(findValue(a, (u16)1));              // T5 — hits on element 0
        Assert.isTrue(findValue(a, (u16)4));              //      hits on the last
        Assert.isFalse(findValue(a, (u16)99));            //      misses (full walk)
    }
    Assert.isEqual(gGone, (u16)0);                        // T2 — nothing released

    // ── T4: break, rather than return.
    for (u16 i = (u16)0; i < (u16)10; i++) {
        Assert.isEqual(firstMatch(a, (u16)2), (u16)2);
    }
    Assert.isEqual(gGone, (u16)0);                        // T4

    // ── T7: nested, inner early return.
    for (u16 i = (u16)0; i < (u16)10; i++) {
        Assert.isTrue(anyPair(a));                        // 3+4 == 7
    }
    Assert.isEqual(gGone, (u16)0);                        // T7

    // ── T3: the container is intact, and its elements are alive.
    Assert.isEqual(a.count(), (u16)4);                    // T3a
    Item* still = (Item* ?)a.get((u16)0);
    Assert.isTrue(still != 0);
    Assert.isEqual(still.v, (u16)1);                      // T3b — not freed

    // ── T6: the class-Enumerable path (Set), early return.
    Set* s = new Set();
    for (i16 i = (i16)1; i <= (i16)4; i = i + (i16)1) s.add(Number.with(i));
    for (u16 i = (u16)0; i < (u16)10; i++) {
        Assert.isTrue(setHas(s, (i16)1));
        Assert.isTrue(setHas(s, (i16)4));
        Assert.isFalse(setHas(s, (i16)9));
    }
    Assert.isEqual(s.count(), (u16)4);                    // T6 — Set intact
    Assert.isTrue(s.contains(Number.with((i16)1)));       // …and still queryable

    Assert.summary();
    return;
}
