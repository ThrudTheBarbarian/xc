// foundation_array_basic.xc — Array.xc construction + read/write API.
//
//   T1   empty Array starts with count=0 and isEmpty=true.
//   T2   add appends; count tracks the live element total.
//   T3   get returns the element at the given index.
//   T4   first / last shortcut to slot 0 and slot count-1.
//   T5   set replaces an element in-place without changing count.
//   T6   insert at index shifts the tail right.
//   T7   insert at end is equivalent to add.
//
// Companion fixture foundation_array_grow.xc covers remove*, capacity
// growth, and identity search. Split apart so the per-test main code
// stays under xt-heap's 8 KB main region; the merged surface
// overflows by ~2.5 KB.
//
// Heap-capable targets only.

#import "Stdio.xc"
#import "Number.xc"
#import "Array.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // T1
    Array* a = new Array();
    Assert.isEqual(a.count(), (u16)0);                           // T1a
    Assert.isTrue(a.isEmpty());                                  // T1b

    // T2 / T3 / T4
    Number* n0 = Number.withI16(10);
    Number* n1 = Number.withI16(20);
    Number* n2 = Number.withI16(30);
    a.add(n0);
    a.add(n1);
    a.add(n2);
    Assert.isEqual(a.count(), (u16)3);                           // T2
    Assert.isFalse(a.isEmpty());                                 // T2b
    Assert.isEqual(((Number*)a.get((u16)1)).asI16(), (i16)20);   // T3
    Assert.isEqual(((Number*)a.first()).asI16(),    (i16)10);    // T4a
    Assert.isEqual(((Number*)a.last()).asI16(),     (i16)30);    // T4b

    // T5: set replaces in-place.
    Number* n99 = Number.withI16(99);
    a.set((u16)1, n99);
    Assert.isEqual(((Number*)a.get((u16)1)).asI16(), (i16)99);   // T5a
    Assert.isEqual(a.count(), (u16)3);                           // T5b — unchanged

    // T6: insert in the middle, shifting tail right.
    //   before: [10, 99, 30]
    //   insert(1, 77) → [10, 77, 99, 30]
    Number* n77 = Number.withI16(77);
    a.insert((u16)1, n77);
    Assert.isEqual(a.count(), (u16)4);                           // T6a
    Assert.isEqual(((Number*)a.get((u16)0)).asI16(), (i16)10);   // T6b
    Assert.isEqual(((Number*)a.get((u16)1)).asI16(), (i16)77);   // T6c
    Assert.isEqual(((Number*)a.get((u16)2)).asI16(), (i16)99);   // T6d
    Assert.isEqual(((Number*)a.get((u16)3)).asI16(), (i16)30);   // T6e

    // T7: insert at end == add.
    Number* nEnd = Number.withI16(50);
    a.insert(a.count(), nEnd);
    Assert.isEqual(a.count(), (u16)5);                           // T7a
    Assert.isEqual(((Number*)a.last()).asI16(), (i16)50);        // T7b

    Assert.summary();
    return;
}
