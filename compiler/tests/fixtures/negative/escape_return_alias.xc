// Returning through a short pointer-alias chain is still a hard
// error — the analyser traces `q = &p` and flags `return q`.
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
    Point* q = &p;
    return q;
}

void main(void) { Point* z = leak(); }
