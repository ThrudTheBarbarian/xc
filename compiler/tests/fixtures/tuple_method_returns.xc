// A method may return several values, as a free function may. Declaring one
// failed to parse ("Expected 'identifier' but found ','"), unpacking a method
// call's values was refused in lowering, `return f();` in a function returning
// several values handed back only f's first value, `return 1, 2` into
// `u8, u16` built a U8 into the U16 field, and the reference's multi-value
// return never released the `self` a method retains on entry (dealloc below).
#import "Stdio.xc"

class Box : Object { i32 v; }

Box*, bool freeFind(void)
    {
    Box* b = new Box();
    b.v = 7;
    return b, true;
    }

Box*, bool freeForward(void) { return freeFind(); }

class T : Object
    {
    i32 base;
    u8, u16 scalars(void) { return 1, 2; }
    i32, i32 twice(i32 x) { return x + base, (x + base) * 2; }
    Box*, bool find(void) { return freeFind(); }
    u8, u16 forward(void) { return scalars(); }
    i32 sum(void)
        {
        (i32 a, i32 b) = twice(10);   // through the implicit self
        return a + b;
        }
    static i64, bool big(void) { return 5000000000, false; }
    i32, i32 which(void) { return 1, 0; }
    void dealloc(void) { Stdio.printf("freed %d\n", base); }
    }

class U : T
    {
    i32, i32 which(void) { return 2, base; }
    }

i32 main(void)
    {
    T* t = new T();
    t.base = 5;
    (u8 x, u16 y) = t.scalars();
    Stdio.printf("scalars %d %d\n", (i32)x, (i32)y);
    (Box* c, bool ok) = t.find();
    Stdio.printf("find %d %d\n", c.v, (i32)ok);
    (Box* d, bool ok2) = freeForward();
    Stdio.printf("forward %d %d\n", d.v, (i32)ok2);
    (u8 p, u16 q) = t.forward();
    Stdio.printf("method forward %d %d\n", (i32)p, (i32)q);
    (i32 m, i32 n) = t.twice(1);
    Stdio.printf("twice %d %d, sum %d\n", m, n, t.sum());
    (i64 g, bool h) = T.big();
    Stdio.printf("static %ld %d\n", g, (i32)h);
    (i32 b1, i32 b2) = t.which();
    Stdio.printf("base %d %d\n", b1, b2);
    U* u = new U();
    u.base = 9;
    T* asT = u;
    (i32 w1, i32 w2) = asT.which();
    Stdio.printf("override %d %d\n", w1, w2);
    return 0;
    }
