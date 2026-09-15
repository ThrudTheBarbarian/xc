// Storing the address of a stack instance in a global outlives the
// stack frame — warning (silenceable since some patterns clear the
// global before scope exit).
// xtc: warn "storing address of stack-allocated 'p' in global 'gPtr'"

class Point
{
    u8 x;
    u8 y;
    void set(u8 nx, u8 ny) { x = nx; y = ny; }
}

Point* gPtr;

void stash(void)
{
    Point p;
    p.set(3, 4);
    gPtr = &p;
}

void main(void) { stash(); }
