// arc_nested_chain.xc — ARC handling for nested member-access
// chains like `a.b.c = x` where `c` is a strong class pointer.
//
// Before this landing the ARC member-store intercept only matched
// single-level `base.field = x`. Nested writes fell through to
// the non-ARC path which emitted a plain byte-level store with
// no release-old / retain-new dance. Reassigning a deeply nested
// strong field leaked the prior value and didn't own the new one
// — scope-exit would then decref whatever was there last and
// potentially double-free.
//
// Topology:
//   Leaf    { u8 tag; dealloc() { leafDealloc++; } }
//   struct Inner { Leaf@ leaf; u8 flags; }
//   struct Outer { Inner mid; u16 count; }
//
// `Outer o; o.mid.leaf = new Leaf();` exercises the chain-walker
// via flattenStructFieldChain. Reassigning `o.mid.leaf` to a new
// Leaf must release the old one.
//
// Flat-heap only — banked-heap ARC is Phase 4.

#import "Stdio.xc"
#import "Assert.xc"

u16 leafDealloc;
u16 midCount1;
u16 midCount2;

class Leaf
{
    u8 tag;
    void dealloc(void)
    {
        leafDealloc = leafDealloc + 1;
    }
}

struct Inner
{
    Leaf* leaf;
    u8    flags;
}

struct Outer
{
    Inner mid;
    u16   count;
}

void exerciseNested(void)
{
    Outer o;
    o.count = 0;

    // First nested store: chain flattens to (o, offset), releases
    // null slot (no-op), stores Leaf#1 at o.mid.leaf.
    o.mid.leaf = new Leaf();
    o.mid.leaf.tag = 11;
    o.mid.flags = 1;
    midCount1 = leafDealloc;                       // expect 0

    // Second nested store: release Leaf#1, store Leaf#2.
    o.mid.leaf = new Leaf();
    o.mid.leaf.tag = 22;
    midCount2 = leafDealloc;                       // expect 1

    // Scope exit walks the struct's strong fields through the
    // aggregate walker (struct-in-struct recurses) and releases
    // o.mid.leaf (Leaf#2) → leafDealloc becomes 2.
}

void main(void)
{
    Assert.reset();
    leafDealloc = 0;
    midCount1 = $FF;
    midCount2 = $FF;

    exerciseNested();

    Assert.isEqual(midCount1, 0);                   // T1 first store — no dealloc
    Assert.isEqual(midCount2, 1);                   // T2 second store released Leaf#1
    Assert.isEqual(leafDealloc, 2);                 // T3 scope-exit released Leaf#2

    Assert.summary();
    return;
}
