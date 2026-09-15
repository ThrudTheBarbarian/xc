// arc_transitive_dealloc.xc — ARC 2f transitive aggregate walker.
//
// A class whose ivar is a strong pointer to another class-with-
// strong-ivars releases *all* levels on the final scope-exit
// decref. Without the transitive walk (the single-level behaviour
// we shipped first) the deepest class's ivars leaked forever.
//
// Class tree:
//   Outer  { Middle@ mid; }
//   Middle { Leaf@   leaf; }
//   Leaf   { u8 tag; dealloc() { leafDealloc++; } }
//
// Path: the helper `buildReadAndDrop()` builds the tree in a
// tracked strong local, reads the deepest tag, and returns it
// as a u8. Scope-exit releases `o` → Outer refcount 0 →
// Outer.dealloc runs → aggregate walker releases `mid` → Middle
// refcount 0 → Middle.dealloc + walker releases `leaf` →
// Leaf.dealloc. The scalar return survives the cleanup (stashed
// on the hw stack), so T1 proves the chain was live when read
// and T2-T4 prove every level's dealloc fired.
//
// Flat-heap only — banked-heap ARC is Phase 4.

#import "Stdio.xc"
#import "Assert.xc"

u16 outerDealloc;
u16 middleDealloc;
u16 leafDealloc;

class Leaf
{
    u8 tag;
    void dealloc(void)
    {
        leafDealloc = leafDealloc + 1;
    }
}

class Middle
{
    Leaf* leaf;
    void dealloc(void)
    {
        middleDealloc = middleDealloc + 1;
    }
}

class Outer
{
    Middle* mid;
    void dealloc(void)
    {
        outerDealloc = outerDealloc + 1;
    }
}

u8 buildReadAndDrop(void)
{
    // Owns the tree in a tracked strong local. Reads the deepest
    // field and returns it — the scalar return path has to survive
    // scope-exit cleanup that releases the tree. Cleanup then
    // releases `o` → Outer refcount 0 → Outer.dealloc runs →
    // aggregate walker releases `mid` → Middle refcount 0 →
    // Middle.dealloc + walker releases `leaf` → Leaf.dealloc. All
    // three counts bump by 1 before this function returns.
    Outer* o   = new Outer();
    o.mid      = new Middle();
    o.mid.leaf = new Leaf();
    o.mid.leaf.tag = 42;
    return o.mid.leaf.tag;
}

void main(void)
{
    Assert.reset();
    outerDealloc  = 0;
    middleDealloc = 0;
    leafDealloc   = 0;

    u8 tag = buildReadAndDrop();

    Assert.isEqual(tag, 42);                         // T1 — scalar survived cleanup
    Assert.isEqual(outerDealloc,  1);                // T2
    Assert.isEqual(middleDealloc, 1);                // T3 — transitive walk
    Assert.isEqual(leafDealloc,   1);                // T4 — deepest class reached

    Assert.summary();
    return;
}
