// arc_two_loops_same_name.xc — private:docs/bugs/024.
//
// A C-style `for` pushes no ARC scope of its own, so a loop variable is
// enrolled in the ENCLOSING scope's frame. Two loops in one function that both
// declare `Leaf@ c` therefore enrolled the name TWICE in the same frame — and
// the frame is a list of names whose teardown releases the name's current
// binding once per entry. Every exit after the second loop released it twice.
//
// The victim is a BORROWED object: the list element still has a real owner, so
// nothing goes wrong at the release. It goes wrong later, when the allocator
// hands the freed block to somebody else — which is why this first showed up
// as a failed downcast in an unrelated part of the self-hosted front end.
//
// Renaming either loop variable hides it, so the fixture keeps them the same
// on purpose.

#import "Foundation.xc"
#import "Stdio.xc"

class Leaf
{
    Leaf* next;
    u16   v;
}

// Hands back something the caller does NOT own.
Leaf* step(Leaf* p) { return p.next; }

u16 probe(Leaf* head)
{
    bool any = false;
    for (Leaf* c = head; c != 0; c = step(c)) any = true;
    if (!any) { return (u16)0; }
    // Same name as the loop above, and it leaves early.
    for (Leaf* c = head; c != 0; c = step(c)) {
        if (c.v == (u16)$DE) { return c.v; }
    }
    return (u16)0;
}

void main(void)
{
    Leaf* a = new Leaf();  a.v = (u16)$DE;
    Leaf* b = new Leaf();  b.v = (u16)$AD;
    Leaf* c = new Leaf();  c.v = (u16)$BE;
    a.next = b;  b.next = c;

    // Enough turns that a freed block is certain to be handed out again.
    for (u32 i = (u32)0; i < (u32)200; i = i + (u32)1) { probe(a); }

    Stdio.printf("%d %d %d\n", a.v, b.v, c.v);
}
