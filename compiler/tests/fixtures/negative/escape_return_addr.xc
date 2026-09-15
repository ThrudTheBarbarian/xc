// Returning the address of a stack-allocated instance is a hard
// error — the storage dies at the closing brace.
// xtc: error "cannot return address or value derived from stack-allocated instance 'p'"

class Point
{
    u8 x;
    u8 y;
    void set(u8 nx, u8 ny) { x = nx; y = ny; }
}

Point* leak(void)
{
    Point p;
    p.set(1, 2);
    return &p;
}

void main(void) { Point* q = leak(); }
