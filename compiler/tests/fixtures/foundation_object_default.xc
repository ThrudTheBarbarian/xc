// foundation_object_default.xc — Object's universal Hashable+Comparable.
//
// Every class without an explicit parent implicitly inherits from
// Object. Object provides default pointer-equality `equals` and
// pointer-fold `hash`, so any user-defined class is immediately
// usable as a Map key (or any other Hashable/Comparable consumer)
// without writing the methods by hand.
//
//   T1   Two distinct instances of a plain class compare unequal.
//   T2   The same pointer compares equal to itself.
//   T3   An aliased pointer compares equal to its source.
//   T4   Distinct instances hash apart (heap addresses differ).
//   T5   Reaching equals through a Hashable@ protocol pointer
//        works — the protocol vtable picks up Object's slot.
//   T6   Same for hash() through Hashable@.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

class Box
{
    u16 x;
}

void main(void)
{
    Assert.reset();

    Box* a = new Box();
    Box* b = new Box();
    Box* c = a;

    Assert.isFalse(a.equals(b));                          // T1
    Assert.isTrue(a.equals(a));                           // T2
    Assert.isTrue(a.equals(c));                           // T3
    Assert.isFalse(a.hash() == b.hash());                 // T4

    Hashable* ha = a;
    Hashable* hb = b;
    Object*   ob = b;
    Object*   oa = a;
    Assert.isFalse(ha.equals(ob));                        // T5a
    Assert.isTrue(ha.equals(oa));                         // T5b
    Assert.isFalse(ha.hash() == hb.hash());               // T6

    Assert.summary();
    return;
}
