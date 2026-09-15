// :cloaked functions can't call `new` — the heap allocator pushes
// to the xtc stack, and that stack is hidden while PORTB is $30.
// Sema catches this regardless of target (it's a property of the
// annotation, not the memory model).
// xtc: error ":cloaked 'leak' cannot use 'new'"

class Point { u8 x; u8 y; }

void leak(void) : cloaked
{
    Point* p = new Point();
    p.x = 1;
}

void main(void) { }
