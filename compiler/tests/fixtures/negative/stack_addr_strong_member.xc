// A class instance held by value inside another has no header of its own, so
// a strong pointer cannot hold its address, and the owner does not move to
// the heap for it (#604).
// xtc: error "'&o.inner' points inside o, and a pointer into an instance cannot be counted; copy the member out (P c = o.inner;), or allocate it with new"

class P : Object { i32 a; i32 b; }
class Outer : Object { i32 k; P inner; }

i32 main(void)
    {
    Outer o;
    o.inner.a = 2;
    P* r = &o.inner;
    return r.a;
    }
