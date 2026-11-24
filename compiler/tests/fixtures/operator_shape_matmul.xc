// `@`, matrix multiplication, as in Python and NumPy: `*` stays element-wise.
// `@` is free since the old pointer sigil was retired, and binds like `*`.
#import <Stdio.xc>

class M2
    {
    i32 a;
    i32 b;
    i32 c;
    i32 d;
    static M2* of(i32 p, i32 q, i32 r, i32 s) { M2* m = new M2(); m.a = p; m.b = q; m.c = r; m.d = s; return m; }
    M2* mm(M2* o) :operator(self @ o)
        {
        return M2.of(a * o.a + b * o.c, a * o.b + b * o.d, c * o.a + d * o.c, c * o.b + d * o.d);
        }
    M2* ew(M2* o) :operator(self * o) { return M2.of(a * o.a, b * o.b, c * o.c, d * o.d); }
    M2* add(M2* o) :operator(self + o) { return M2.of(a + o.a, b + o.b, c + o.c, d + o.d); }
    }

i32 main(void)
    {
    M2* x = M2.of(1, 2, 3, 4);
    M2* y = M2.of(5, 6, 7, 8);
    M2* p = x @ y;
    Stdio.printf("mm %d %d %d %d\n", p.a, p.b, p.c, p.d);
    M2* q = x * y;
    Stdio.printf("ew %d %d %d %d\n", q.a, q.b, q.c, q.d);
    M2* r = x + x @ y;
    Stdio.printf("prec %d %d %d %d\n", r.a, r.b, r.c, r.d);
    return 0;
    }
