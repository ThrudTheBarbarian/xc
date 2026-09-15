// foundation_set_algebra.xc — the operations that make a Set worth having.
//
// A Set could only add, contain and remove. It could not answer "who is in
// both", "who is new", "who went away" — which is most of what a set is FOR.
// Without them a Set is just a slower Array with deduplication.
//
// Map, likewise, could not hand back its keys or its values, and its `contains`
// was written as `get(key) != 0` — so a key stored with a null value read as
// absent. That is a different question from the one the caller asked.
//
//   T1  union / intersect / subtract / symmetricDifference
//   T2  the receiver and the argument are NOT modified by any of them
//   T3  relations: isSubsetOf / isSupersetOf / intersects / isDisjointFrom
//   T4  equalsSet — same members, any order
//   T5  allObjects / withArray round-trip
//   T6  Map: allKeys / allValues / containsKey / getOrDefault
//   T7  containsKey is about the KEY, not the value — a key with a null value
//       is still present
//   T8  the empty and disjoint edge cases

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

// Sets have no order, so compare them by membership.
bool hasN(Set* s, i16 v)
{
    return s.contains(Number.with(v));
}

Set* setOf(i16 lo, i16 hi)
{
    Set* s = new Set();
    for (i16 i = lo; i <= hi; i = i + (i16)1) s.add(Number.with(i));
    return s;
}

void t1_t2(void)
{
    Set* a = setOf((i16)1, (i16)5);          // {1,2,3,4,5}
    Set* b = setOf((i16)4, (i16)8);          // {4,5,6,7,8}

    // ── T1.
    Set* u = a.unionWith(b);
    Assert.isEqual(u.count(), (u16)8);                        // T1a — {1..8}
    Assert.isTrue(hasN(u, (i16)1));
    Assert.isTrue(hasN(u, (i16)8));

    Set* i = a.intersect(b);
    Assert.isEqual(i.count(), (u16)2);                        // T1b — {4,5}
    Assert.isTrue(hasN(i, (i16)4));
    Assert.isTrue(hasN(i, (i16)5));
    Assert.isFalse(hasN(i, (i16)3));

    Set* d = a.subtract(b);
    Assert.isEqual(d.count(), (u16)3);                        // T1c — {1,2,3}
    Assert.isTrue(hasN(d, (i16)1));
    Assert.isFalse(hasN(d, (i16)4));

    Set* x = a.symmetricDifference(b);
    Assert.isEqual(x.count(), (u16)6);                        // T1d — {1,2,3,6,7,8}
    Assert.isTrue(hasN(x, (i16)3));
    Assert.isTrue(hasN(x, (i16)6));
    Assert.isFalse(hasN(x, (i16)4));                          // the shared ones drop out

    // ── T2: none of that touched the operands.
    Assert.isEqual(a.count(), (u16)5);                        // T2a
    Assert.isEqual(b.count(), (u16)5);                        // T2b
    Assert.isTrue(hasN(a, (i16)1));
    Assert.isTrue(hasN(b, (i16)8));
}

void t3(void)
{
    Set* a = setOf((i16)1, (i16)5);
    Set* b = setOf((i16)4, (i16)8);
    Set* small = setOf((i16)2, (i16)3);       // {2,3} ⊂ a
    Set* far   = setOf((i16)90, (i16)92);     // disjoint from everything

    // ── T3.
    Assert.isTrue(small.isSubsetOf(a));                       // T3a
    Assert.isFalse(a.isSubsetOf(small));
    Assert.isTrue(a.isSupersetOf(small));                     // T3b
    Assert.isTrue(a.intersects(b));                           // T3c — share 4,5
    Assert.isFalse(a.intersects(far));
    Assert.isTrue(a.isDisjointFrom(far));                     // T3d
    Assert.isFalse(a.isDisjointFrom(b));

    // A set is a subset of itself.
    Assert.isTrue(a.isSubsetOf(a));                           // T3e

}

void t4_t5(void)
{
    Set* a = setOf((i16)1, (i16)5);
    Set* b = setOf((i16)4, (i16)8);
    Set* small = setOf((i16)2, (i16)3);

    // ── T4: same members, any order.
    Set* aAgain = new Set();
    aAgain.add(Number.with((i16)5)); aAgain.add(Number.with((i16)3));
    aAgain.add(Number.with((i16)1)); aAgain.add(Number.with((i16)4));
    aAgain.add(Number.with((i16)2));
    Assert.isTrue(a.equalsSet(aAgain));                       // T4a — order irrelevant
    Assert.isFalse(a.equalsSet(b));                           // T4b
    Assert.isFalse(a.equalsSet(small));                       // T4c — subset != equal

    // ── T5: to an Array and back.
    Array* arr = a.allObjects();
    Assert.isEqual(arr.count(), (u16)5);                      // T5a
    Set* back = Set.withArray(arr);
    Assert.isTrue(a.equalsSet(back));                         // T5b

    // Duplicates in the Array collapse in the Set.
    Array* dup = new Array();
    dup.add(Number.with((i16)7));
    dup.add(Number.with((i16)7));
    dup.add(Number.with((i16)8));
    Assert.isEqual(Set.withArray(dup).count(), (u16)2);       // T5c
}

void t6_t7_t8(void)
{
    // ── T6: Map views.
    Map* m = new Map();
    m.set(String.withCString("a"), Number.with((i16)1));
    m.set(String.withCString("b"), Number.with((i16)2));
    m.set(String.withCString("c"), Number.with((i16)3));

    Assert.isEqual(m.allKeys().count(),   (u16)3);            // T6a
    Assert.isEqual(m.allValues().count(), (u16)3);            // T6b
    Assert.isTrue(m.containsKey(String.withCString("b")));    // T6c
    Assert.isFalse(m.containsKey(String.withCString("z")));

    Number* got = (Number* ?)m.getOrDefault(String.withCString("b"), Number.with((i16)99));
    Assert.isEqual(got.asI16(), (i16)2);                      // T6d — present
    Number* dflt = (Number* ?)m.getOrDefault(String.withCString("z"), Number.with((i16)99));
    Assert.isEqual(dflt.asI16(), (i16)99);                    // T6e — absent

    // ── T7: a key stored with a NULL value is still a key. `contains` used to
    // be `get(key) != 0`, which answered a different question and said no.
    m.set(String.withCString("null"), (Object*)0);
    Assert.isTrue(m.containsKey(String.withCString("null")));  // T7a
    Assert.isEqual(m.count(), (u16)4);                         // T7b

    // ── T8: empties and degenerate cases.
    Set* e = new Set();
    Assert.isEqual(e.unionWith(e).count(), (u16)0);            // T8a
    Assert.isEqual(e.intersect(setOf((i16)1,(i16)3)).count(), (u16)0);
    Assert.isTrue(e.isSubsetOf(setOf((i16)1,(i16)3)));         // T8b — empty ⊆ anything
    Assert.isTrue(e.isDisjointFrom(setOf((i16)1,(i16)3)));     // T8c
    Assert.isTrue(e.equalsSet(new Set()));                     // T8d

    Set* one = setOf((i16)1, (i16)1);
    Assert.isEqual(one.subtract(one).count(), (u16)0);         // T8e — self-difference
    Assert.isTrue(one.intersect(one).equalsSet(one));          // T8f
}

void main(void)
{
    t1_t2();
    t3();
    t4_t5();
    t6_t7_t8();
    Assert.summary();
    return;
}
