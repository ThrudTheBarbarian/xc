// Storing the address of a field of a stack instance in a global outlives the
// instance — warning (silenceable since some patterns clear the global
// before scope exit). `&p` itself moves p to the heap (#604); a pointer into
// it does not.
// xtc: warn "storing address of stack-allocated 'p' in global 'gX'"

class Point
{
    u8 x;
    u8 y;
    void set(u8 nx, u8 ny) { x = nx; y = ny; }
}

u8* gX;

void stash(void)
{
    Point p;
    p.set(1, 2);
    gX = &p.x;
}

void main(void)
{
    stash();
}
