// A function returning a class by value whose `return` is a call to one
// that returns it by value hands the instance back by value: its object
// ivar is released once, after its last use (#758). It used to return a
// pointer to its own slot, torn down first. A free function, a static
// method, and a chain of two.
#import "Stdio.xc"

class Box
    {
    i32 v;
    void dealloc(void) { Stdio.printf("dealloc %d\n", v); }
    }

class V
    {
    Box* _b;
    i32 n;
    static V make(i32 k)
        {
        V t;
        t._b = new Box();
        t._b.v = k;
        t.n = k;
        return t;
        }
    }

V makeV(i32 k)
    {
    V t;
    t._b = new Box();
    t._b.v = k;
    t.n = k;
    return t;
    }

V viaFree(void) { return makeV(2); }
V viaStatic(void) { return V.make(3); }
V viaChain(void) { return viaFree(); }

i32 main(void)
    {
    V a = viaFree();
    Stdio.printf("a %d %d\n", (i16)a.n, a._b.v);
    V b = viaStatic();
    Stdio.printf("b %d %d\n", (i16)b.n, b._b.v);
    V c = viaChain();
    Stdio.printf("c %d %d\n", (i16)c.n, c._b.v);
    return 0;
    }
