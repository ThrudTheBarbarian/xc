// A stack class instance returned by value. It used to come back as the
// address of the callee's own instance, in a frame already gone: a free
// function's caller stored that pointer as the instance's first word and read
// garbage, and a method's caller copied out in time only by luck (UXKit,
// 2026-10-28). Now the instance travels as its bytes, as a struct does, and a
// plain copy `V q = p;` / `r = p;` copies them too. Each case clobbers the
// stack between the return and the read.
#import <Stdio.xc>

class Vec2
    {
    float x;
    float y;
    float sum(void) { return x + y; }
    Vec2 scaled(float k)
        {
        Vec2 r;
        r.x = x * k;
        r.y = y * k;
        return r;
        }
    }

class Big
    {
    i32 a; i32 b; i32 c; i32 d; i32 e; i32 f;
    }

Vec2 make(float a, float b)
    {
    Vec2 v;
    v.x = a;
    v.y = b;
    return v;
    }

Vec2 add(Vec2 p, Vec2 q)
    {
    Vec2 r;
    r.x = p.x + q.x;
    r.y = p.y + q.y;
    return r;
    }

Vec2 forward(float a) { return make(a, a + 1.0); }

Big big(i32 s)
    {
    Big g;
    g.a = s; g.b = s + 1; g.c = s + 2; g.d = s + 3; g.e = s + 4; g.f = s + 5;
    return g;
    }

// Writes over the stack below the caller, where a dead callee frame was.
i32 clobber(i32 n)
    {
    i32 junk[64];
    for (i32 i = 0; i < 64; i = i + 1)
        junk[i] = n * 1000 + i;
    return junk[n & 63];
    }

// A method returning by value, overridden: the call dispatches.
class Shape : Object
    {
    Vec2 centre(void) { Vec2 c; c.x = 1.0; c.y = 1.0; return c; }
    }

class Square : Shape
    {
    Vec2 centre(void) { Vec2 c; c.x = 2.0; c.y = 3.0; return c; }
    }

i32 centreSum(Shape* s)
    {
    Vec2 c = s.centre();
    clobber(2);
    return (i32)c.x * 10 + (i32)c.y;
    }

i32 main(void)
    {
    Vec2 a = make(1.0, 2.0);
    clobber(7);
    Stdio.printf("decl %d %d\n", (i32)a.x, (i32)a.y);
    Vec2 b = make(10.0, 20.0);
    Vec2 c = add(a, b);
    clobber(9);
    Stdio.printf("add %d %d\n", (i32)c.x, (i32)c.y);
    Vec2 d;
    d = make(5.0, 6.0);
    clobber(3);
    Stdio.printf("assign %d %d\n", (i32)d.x, (i32)d.y);
    Vec2 e = a.scaled(3.0);
    clobber(4);
    Stdio.printf("method %d %d\n", (i32)e.x, (i32)e.y);
    Stdio.printf("rvalue %d %d %d\n", (i32)make(7.0, 8.0).x, (i32)make(7.0, 8.0).sum(), (i32)forward(4.0).y);
    Big g = big(100);
    clobber(5);
    Stdio.printf("big %d %d %d\n", g.a, g.c, g.f);
    i32 t = 0;
    for (i32 i = 0; i < 4; i = i + 1)
        {
        Vec2 v = make((float)i, (float)(i * 2));
        clobber(i);
        t = t + (i32)v.x + (i32)v.y;
        }
    Stdio.printf("loop %d\n", t);
    Shape* sh = new Shape();
    Shape* sq = new Square();
    Stdio.printf("virtual %d %d\n", centreSum(sh), centreSum(sq));
    // A plain copy takes the bytes (owner, 2026-10-28), and the two stay
    // independent.
    Vec2 p = make(1.0, 2.0);
    Vec2 q = p;
    Vec2 r2;
    r2 = p;
    p.x = 9.0;
    clobber(6);
    Stdio.printf("copy %d %d %d %d %d\n", (i32)q.x, (i32)q.y, (i32)r2.x, (i32)r2.y, (i32)p.x);
    return 0;
    }
