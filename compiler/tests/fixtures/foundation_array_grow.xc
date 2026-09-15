// foundation_array_grow.xc — Array.xc remove*, capacity growth, identity search.
//
//   T1   removeAt shifts the tail left and drops the count.
//   T2   removeFirst / removeLast wrappers.
//   T3   removeAll resets to empty.
//   T4   withCapacity preallocates so the first 4 adds fit without
//        a resize copy.
//   T5   growth across the resize boundary preserves contents.
//   T6   indexOf / contains use pointer identity, not value equality.
//
// Companion fixture foundation_array_basic.xc covers construction,
// add, get, first, last, set, insert. Split apart so the per-test
// main code stays under xt-heap's 8 KB main region.
//
// Heap-capable targets only.

#import "Stdio.xc"
#import "Number.xc"
#import "Array.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // Build [10, 77, 99, 30, 50] up front so the remove* tests have
    // a non-trivial array to chew through.
    Array* a = new Array();
    a.add(Number.withI16(10));
    a.add(Number.withI16(77));
    a.add(Number.withI16(99));
    a.add(Number.withI16(30));
    a.add(Number.withI16(50));

    // T1: removeAt(2) — drops 99.
    //   before: [10, 77, 99, 30, 50]
    //   after:  [10, 77, 30, 50]
    a.removeAt((u16)2);
    Assert.isEqual(a.count(), (u16)4);                           // T1a
    Assert.isEqual(((Number*)a.get((u16)2)).asI16(), (i16)30);   // T1b

    // T2: removeFirst / removeLast.
    //   before: [10, 77, 30, 50]
    //   removeFirst → [77, 30, 50]
    //   removeLast  → [77, 30]
    a.removeFirst();
    a.removeLast();
    Assert.isEqual(a.count(), (u16)2);                           // T2a
    Assert.isEqual(((Number*)a.first()).asI16(), (i16)77);       // T2b
    Assert.isEqual(((Number*)a.last()).asI16(),  (i16)30);       // T2c

    // T3: removeAll.
    a.removeAll();
    Assert.isEqual(a.count(), (u16)0);                           // T3a
    Assert.isTrue(a.isEmpty());                                  // T3b

    // T4: withCapacity pre-sizes.
    Array* b = Array.withCapacity((u16)4);
    Assert.isEqual(b.capacity(), (u16)4);                        // T4a
    Assert.isEqual(b.count(),    (u16)0);                        // T4b
    b.add(Number.withI16(1));
    b.add(Number.withI16(2));
    b.add(Number.withI16(3));
    b.add(Number.withI16(4));
    Assert.isEqual(b.capacity(), (u16)4);                        // T4c — no resize
    Assert.isEqual(b.count(),    (u16)4);                        // T4d

    // T5: growth across the resize boundary preserves contents.
    // The default starting capacity is 8; pushing through 8 → 16
    // exercises _grow's copy.
    Array* c = new Array();
    for (u16 i = (u16)0; i < (u16)10; i++) c.add(Number.withU16(i + (u16)100));
    Assert.isEqual(c.count(),    (u16)10);                       // T5a
    Assert.isEqual(c.capacity(), (u16)16);                       // T5b — doubled
    Assert.isEqual(((Number*)c.get((u16)0)).asU16(), (u16)100);  // T5c
    Assert.isEqual(((Number*)c.get((u16)9)).asU16(), (u16)109);  // T5d

    // T6: indexOf / contains — pointer identity.
    Array* d = new Array();
    Number* p1 = Number.withI16(7);
    Number* p2 = Number.withI16(7);   // same value, different instance
    d.add(p1);
    Assert.isEqual(d.indexOf(p1), (u16)0);                       // T6a
    // Not-found is Array.notFound(), NOT a hardcoded $FFFF: on the 32-bit
    // Foundation an index is u32, and $FFFF is a perfectly valid index there.
    Assert.isEqual(d.indexOf(p2), Array.notFound());             // T6b — not found
    Assert.isTrue(d.contains(p1));                               // T6c
    Assert.isFalse(d.contains(p2));                              // T6d

    Assert.summary();
    return;
}
