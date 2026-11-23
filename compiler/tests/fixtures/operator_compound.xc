// Compound assignment through operators. `:operator(self += o)` defines `+=`
// in place: `a += b` is `a.addIn(b)`. A class that defines `-` and no `-=`
// still has `a -= b`: it is `a = a - b`, and the old value of `a` is
// released when the new one is stored. When `+=` takes no argument of b's
// type but `+` does, `a += b` is `a = a + b` too.
//
// A class returned by value has `+` only, so its `+=` is a by-value
// assignment of `a + b` to `a`.
#import <Stdio.xc>

i32 live;
i32 tracked;

class Vec2
    {
    i32 x;
    i32 y;
    void init(void) { live = live + 1; }
    void dealloc(void) { live = live - 1; }
    static Vec2* make(i32 a, i32 b) { Vec2* v = new Vec2(); v.x = a; v.y = b; return v; }
    void addIn(Vec2* o)   :operator(self += o) { x = x + o.x; y = y + o.y; }
    Vec2* minus(Vec2* o)  :operator(self - o)  { return Vec2.make(x - o.x, y - o.y); }
    Vec2* scaled(i32 k)   :operator(self * k)  { return Vec2.make(x * k, y * k); }
    Vec2* plusK(i32 k)    :operator(self + k)  { return Vec2.make(x + k, y + k); }
    }

class Tracker
    {
    void init(void) { tracked = tracked + 1; }
    void dealloc(void) { tracked = tracked - 1; }
    }

class Vec
    {
    i32 x;
    i32 y;
    Tracker* t;
    void init(void) { t = new Tracker(); }
    Vec plus(Vec o) :operator(self + o) { Vec r; r.x = x + o.x; r.y = y + o.y; return r; }
    static void ready(void) { }
    }

class Holder
    {
    Vec2* v;
    }

void show(string label, Vec2* v)
    {
    Stdio.printf("%s %d %d\n", label, v.x, v.y);
    }

void values(void)
    {
    Vec a;
    a.x = 1;
    a.y = 2;
    Vec b;
    b.x = 10;
    b.y = 20;
    a += b;
    a += b;
    Stdio.printf("value %d %d tracked %d\n", a.x, a.y, tracked);
    }

i32 main(void)
    {
    Vec2* a = Vec2.make(1, 2);
    Vec2* b = Vec2.make(10, 20);
    Vec2* same = a;
    a += b;
    show("inplace", a);
    show("same", same);
    a -= b;
    show("fallback", a);
    show("old", same);
    a *= 3;
    show("times", a);
    a += 100;
    show("plusk", a);
    Stdio.printf("live %d\n", live);
    for (i32 i = 0; i < 4; i = i + 1)
        a -= b;
    show("loop", a);
    Stdio.printf("live %d\n", live);
    Holder* h = new Holder();
    h.v = Vec2.make(5, 5);
    h.v *= 2;
    h.v += b;
    show("field", h.v);
    same = 0;
    a = 0;
    b = 0;
    h = 0;
    Stdio.printf("live %d\n", live);

    Vec.ready();
    tracked = 0;
    values();
    Stdio.printf("tracked %d\n", tracked);
    return 0;
    }
