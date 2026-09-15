// heap_w3_multibank.xc — pin the borrowed-init retain at heap-w3.
//
// At heap-w3, `Node@ cur = head;` (decl with another local as
// initialiser) flows through emitLocalVarDecl's `size > 2 +
// IdentifierNode initialiser` arm — historically a struct /
// wide-int byte-copy path that never emitted ARC retain.
// Pre-fix, cur was initialised to head's pointer without
// bumping head's refcount; the next reassignment of cur
// (`cur = cur.next` in a typical traversal) released "old
// cur" which decremented head's refcount to 0 and freed
// head. The next allocation reused head's block and
// silently overwrote head's ivars.
//
// This fixture exercises exactly that pattern in a builder
// loop. Without the retain emit (StmtBodies.m, the size==3
// + arcTypeIsStrongClassPointer path), iteration 1's
// `cur = cur.next` frees head; subsequent allocations alias
// head's storage and the chain walk reads garbage.
//
// Restricted to xe-heap (the only banked-heap layout with
// pointer-width=3 and a heap big enough for the chain).

#import "Stdio.xc"
#import "Assert.xc"

class Node
{
    u8    tag;
    Node* next;
}

// Helper keeps `new Node()` outside the loop body so the new-
// in-loop leak warning doesn't fire. Each call returns +1 and
// the caller transfers ownership into the chain.
Node* makeNode(u8 t)
{
    Node* n = new Node();
    n.tag = t;
    n.next = (Node*)0;
    return n;
}

void main(void)
{
    Assert.reset();

    Node* head = makeNode((u8)0);
    Node* cur = head;       // borrowed-init: must retain head.
    for (u8 i = 1; i < 10; i = i + 1)
    {
        cur.next = makeNode(i);
        cur = cur.next;     // releases prior cur. If borrowed-init
                            // didn't retain on the first pass, head
                            // was alive only via cur — this drops
                            // it to refcount 0, freeing the block.
    }

    // Walk the chain and sum tags. If head was freed mid-build,
    // its block got reused and head.tag now reads stale data.
    u16 sum = 0;
    Node* p = head;
    while ((pointer)p != (pointer)0)
    {
        sum = sum + (u16)p.tag;
        p = p.next;
    }
    Assert.isEqual(sum, 45);   // T1 — 0 + 1 + ... + 9 = 45

    Assert.summary();
    return;
}
