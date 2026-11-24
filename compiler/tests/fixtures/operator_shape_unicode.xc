// An operator from the Unicode Mathematical Operators block: `⊗`, the
// Kronecker product of two 2-vectors. A shape from that block binds like `*`
// and groups from the left, so `a + u ⊗ v` is `a + (u ⊗ v)`.
#import <Stdio.xc>

class Vec
    {
    i32 x;
    i32 y;
    static Vec* of(i32 a, i32 b) { Vec* v = new Vec(); v.x = a; v.y = b; return v; }
    Quad* kron(Vec* o) :operator(self ⊗ o) { return Quad.of(x * o.x, x * o.y, y * o.x, y * o.y); }
    }

class Quad
    {
    i32 a;
    i32 b;
    i32 c;
    i32 d;
    static Quad* of(i32 p, i32 q, i32 r, i32 s) { Quad* m = new Quad(); m.a = p; m.b = q; m.c = r; m.d = s; return m; }
    Quad* plus(Quad* o) :operator(self + o) { return Quad.of(a + o.a, b + o.b, c + o.c, d + o.d); }
    Quad* scale(i32 k) :operator(self ⊗ k) { return Quad.of(a * k, b * k, c * k, d * k); }
    }

i32 main(void)
    {
    Vec* u = Vec.of(1, 2);
    Vec* v = Vec.of(3, 4);
    Quad* k = u ⊗ v;
    Stdio.printf("kron %d %d %d %d\n", k.a, k.b, k.c, k.d);
    Quad* s = k + u ⊗ v ⊗ 2;
    Stdio.printf("sum %d %d %d %d\n", s.a, s.b, s.c, s.d);
    return 0;
    }
