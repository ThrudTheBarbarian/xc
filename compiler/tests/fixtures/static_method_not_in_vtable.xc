// static_method_not_in_vtable.xc — a static method never fills a vtable slot.
//
// Keyed by name alone, a static `hash` or `compare` looks like an override of
// the Hashable or Comparable requirement. It is not one: it has no receiver,
// so a call through the protocol must still reach Object's method.
//
//   T1   hash() through Hashable@ is Object's hash.
//   T2   The static methods still work when called on the class.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

class Digest
{
    u16 x;
    static u32 hash(u32 seed)
        {
        return seed * (u32)31 + (u32)7;
        }
    static i32 compare(i32 a, i32 b)
        {
        return a - b;
        }
}

void main(void)
{
    Assert.reset();

    Digest* d = new Digest();
    Object* o = d;
    Hashable* h = d;

    Assert.isTrue(h.hash() == o.hash());                     // T1
    Assert.isTrue(Digest.hash((u32)1) == (u32)38);           // T2a
    Assert.isTrue(Digest.compare((i32)5, (i32)2) == (i32)3); // T2b

    Assert.summary();
    return;
}
