// memory.xc — ARC, strong vs weak references, and `delete`.
//
// Every class reference is counted. The compiler inserts retain/release; you
// do not write them. An object dies when the last STRONG reference goes.
#import "Foundation.xc"
#import "Stdio.xc"

class Node : Object
{
    String*  _name;
    Node*    _next;      // strong: keeps the next node alive
    weak Node* _prev;    // weak: does NOT keep the previous node alive

    void init(void) { _name = 0; _next = 0; _prev = 0; }
    static Node* named(string n)
    {
        Node* x = new Node();
        x._name = String.withCString(n);
        return x;
    }
    String* description(void) { return _name; }
    void    link(Node* nxt) { _next = nxt; nxt._prev = self; }
    Node*   next(void)   { return _next; }
    weak Node* prev(void) { return _prev; }
    void dealloc(void) { Stdio.printf("  dealloc %@\n", self); }
}

i32 main(void)
{
    // 1. Ordinary lifetime: `head` is the only reference, so the object
    //    lives until the end of the scope.
    Stdio.print("scope A:\n");
    {
        Node* a = Node.named("A");
        Stdio.printf("  made %@\n", a);
    }
    Stdio.print("  (a is gone)\n");

    // 2. A strong chain. Releasing the head releases the whole chain, in
    //    order, because each node holds the next.
    Stdio.print("scope B:\n");
    {
        Node* b1 = Node.named("B1");
        Node* b2 = Node.named("B2");
        b1.link(b2);
        // b2._prev is WEAK, so the pair is not a retain cycle: without that
        // the two would keep each other alive forever and neither would be
        // freed. Weak is how you break a back-reference.
        Node* fwd = b1.next();
        Stdio.printf("  %@ -> %@, and back: %@\n", b1, fwd, b2.prev());
    }
    Stdio.print("  (chain gone)\n");

    // 3. `delete` is for RAW heap blocks — `new T[N]` of a primitive. It is
    //    rejected on a class instance, because ARC already owns that: the
    //    compiler tells you to let the scope release it. So the two models
    //    never overlap and you cannot double-free.
    Stdio.print("raw buffer:\n");
    u16* buf = new u16[4];
    for (u16 i = (u16)0; i < (u16)4; i = i + (u16)1) buf[i] = i * (u16)11;
    Stdio.printf("  buf[3] = %d, length = %d\n", buf[3], (u16)buf.length);
    delete buf;
    Stdio.print("  (deleted)\n");
    return 0;
}
