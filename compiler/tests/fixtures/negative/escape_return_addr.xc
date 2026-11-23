// Returning the address of a stack-allocated instance is a hard
// error — the storage dies at the closing brace.
// xtc: error "returning '&p', the address of a stack instance that ends with this function; return the instance by value ('Point') or allocate it with new"

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
