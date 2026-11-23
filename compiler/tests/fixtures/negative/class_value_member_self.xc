// xtc: error "class 'Node' holds an instance of itself by value through ivar 'next': declare it 'Node* next;'"
// A class cannot hold an instance of itself by value: it would have no size.
class Node { i32 v; Node next; }
i32 main(void) { Node n; n.v = 1; return n.v; }
