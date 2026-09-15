// Passing the address of a stack-allocated class instance into a
// strong class-pointer parameter is a hard error — under ARC the
// callee retains the pointer, which bumps the refcount at a
// non-heap address and corrupts zero-page.
// xtc: error "cannot pass stack-allocated instance 'p' as strong pointer parameter of 'sink'"

class Box
{
    u8 v;
    void set(u8 n) { v = n; }
}

void sink(Box* b)
{
    b.v = 1;
}

void main(void)
{
    Box p;
    p.set(42);
    sink(&p);
}
