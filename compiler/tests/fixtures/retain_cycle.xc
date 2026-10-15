// retain_cycle.xc — the retain-cycle warning: a class whose strong class-pointer
// fields lead back to itself through another class. Two cycles here, each
// reported once at the field that closes it: Parent.kids ↔ Child.dad (two
// classes) and Ring A → B → C → A (three). Grandchild inherits Child's dad, so
// its own strong back-link to Parent is the same cycle through the inherited
// field, not a new one. No warning for Node.next (a list's own type is not a
// cycle), Leaf.owner (weak) or Owner.leaf (no way back). The program itself
// runs; the warnings are the point (sema-diff compares them).
#import "Stdio.xc"

class Node
    {
    Node* next;             // no warning: a list
    u32 v;
    }

class Parent
    {
    Child* kids;
    u32 n;
    }

class Child
    {
    Parent* dad;            // warning: Parent.kids holds Child and Child.dad holds Parent
    }

class Grandchild : Child
    {
    u32 age;
    }

class RingA
    {
    RingB* b;
    }

class RingB
    {
    RingC* c;
    }

class RingC
    {
    RingA* a;               // warning: RingA.b holds RingB, RingB.c holds RingC and RingC.a holds RingA
    }

class Leaf
    {
    weak:Owner* owner;      // no warning: weak
    }

class Owner
    {
    Leaf* leaf;
    }

i32 main(void)
    {
    Owner* o = new Owner();
    o.leaf = new Leaf();
    o.leaf.owner = o;
    Node* n = new Node();
    n.v = (u32)7;
    Stdio.printf("%u %d\n", n.v, (i32)(o.leaf.owner == o ? 1 : 0));
    return (i32)0;
    }
