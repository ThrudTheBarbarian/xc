// A class instance a STATIC method returns by value, bound to a local and
// returned again, is returned by value: its object ivar is released once,
// after its last use (#754). The local was taken for a stack instance's
// method result, so the function returned the address of its own torn-down
// instance and the Box was freed before the caller read it.
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

V grid(i32 k)
    {
    V g = V.make(k);
    return g;
    }

i32 main(void)
    {
    V g = grid(7);
    Stdio.printf("v %d %d\n", (i16)g.n, g._b.v);
    return 0;
    }
