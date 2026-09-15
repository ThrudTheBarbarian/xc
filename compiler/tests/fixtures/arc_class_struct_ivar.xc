// arc_class_struct_ivar.xc — ARC aggregate walker recurses into
// struct-typed class ivars.
//
// Before this fix, a class with a `struct Node inner;` ivar where
// Node had strong-pointer fields would skip the struct ivar at
// dealloc time — the pointer inside leaked forever. Now the ivar
// walker recognises XTStructType ivars with strong fields and
// recurses via emitArcReleaseStrongStructFieldsIndirectAt: so
// every strong pointer in the nested struct gets released at the
// correct class-relative offset.
//
// Topology:
//   Leaf    { u8 tag; dealloc() { leafDealloc++; } }
//   struct Node { Leaf@ payload; u8 flags; }
//   Box     { Node inner; dealloc() { boxDealloc++; } }
//
// `Box@ b = new Box(); b.inner.payload = new Leaf();` — at main
// scope exit Box refcount → 0, Box.dealloc fires, then the ivar
// walker releases Box.inner.payload (which was a strong Leaf@
// field inside the struct), and Leaf.dealloc fires.
//
// Flat-heap only — banked-heap ARC is Phase 4.

#import "Stdio.xc"
#import "Assert.xc"

u16 leafDealloc;
u16 boxDealloc;

class Leaf
{
    u8 tag;
    void dealloc(void)
    {
        leafDealloc = leafDealloc + 1;
    }
}

struct Node
{
    Leaf* payload;
    u8    flags;
}

class Box
{
    Node inner;
    u8   padding;
    void dealloc(void)
    {
        boxDealloc = boxDealloc + 1;
    }
}

u8 buildAndDrop(void)
{
    Box* b = new Box();
    b.inner.payload = new Leaf();
    b.inner.payload.tag = 99;
    b.inner.flags = 7;
    u8 got = b.inner.payload.tag;
    return got;
    // Scope exit releases b → Box.dealloc fires → walker releases
    // b.inner.payload → Leaf.dealloc fires. Leaf count increments.
}

void main(void)
{
    Assert.reset();
    leafDealloc = 0;
    boxDealloc = 0;

    u8 tag = buildAndDrop();

    Assert.isEqual(tag, 99);                         // T1 chain live at read
    Assert.isEqual(boxDealloc, 1);                   // T2 Box dealloc ran
    Assert.isEqual(leafDealloc, 1);                  // T3 walker released struct-embedded strong ivar

    Assert.summary();
    return;
}
