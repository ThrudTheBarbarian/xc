// self_ref_class.xc — class with a `banked:T@` ivar pointing to its
// own type compiles and supports basic ivar access. Pre-bug-fix
// the ARC strong-ivar release walker recursed at compile time on
// the self-referential ivar (`emitArcReleaseStrongIvarsAt` ↔
// `emitArcReleaseStrongIndirectSlot` mutual recursion), SIGSEGV'ing
// the compiler.
//
// Tracked limitation: deep recursive traversal of a chain of
// self-referential nodes (linked-list / tree style) has separate
// runtime issues with the strong-ivar release sequence; manual
// 2-node linkage + access works, which is the basic shape this
// fixture pins.

#import "Stdio.xc"
#import "Assert.xc"

class Node { u16 value; banked:Node* next; }

void main(void)
{
    Assert.reset();
    Node* a = new Node();
    a.value = 100;
    Node* b = new Node();
    b.value = 200;
    a.next = b;

    Assert.isEqual(a.value, 100);
    Assert.isEqual(a.next.value, 200);

    Assert.summary();
    return;
}
