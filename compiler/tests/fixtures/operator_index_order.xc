// `f()[g()] += h()` evaluates f, g and h once each, in source order: the
// base and the index are evaluated first, then the get, then h, then the
// set. The same holds through a class's `+` standing in for `+=`:
// `pts[pick()] += d` is `pts[i] = pts[i] + d` with `pick()` evaluated once.
#import <Stdio.xc>

i32 live;

class Box
    {
    i32 items[4];
    void init(void) { live = live + 1; }
    void dealloc(void) { live = live - 1; }
    i32 at(i32 i) :operator(self[i]) { Stdio.printf("  get %d\n", i); return items[i]; }
    void put(i32 i, i32 x) :operator(self[i] = x) { Stdio.printf("  set %d %d\n", i, x); items[i] = x; }
    }

class Pt
    {
    i32 x;
    void init(void) { live = live + 1; }
    void dealloc(void) { live = live - 1; }
    static Pt* make(i32 a) { Pt* p = new Pt(); p.x = a; return p; }
    Pt* plus(Pt* o) :operator(self + o) { return Pt.make(x + o.x); }
    }

Box* shared;

Box* f(void)
    {
    Stdio.printf("  f\n");
    return shared;
    }

i32 g(void)
    {
    Stdio.printf("  g\n");
    return 2;
    }

i32 h(void)
    {
    Stdio.printf("  h\n");
    return 5;
    }

i32 picks;

i32 pick(void)
    {
    picks = picks + 1;
    return 1;
    }

i32 main(void)
    {
    shared = new Box();
    Stdio.printf("compound\n");
    f()[g()] += h();
    Stdio.printf("again\n");
    f()[g()] *= h();
    Stdio.printf("value %d\n", shared[2]);
    Stdio.printf("set\n");
    f()[g()] = h();

    Pt* pts[3];
    for (i32 i = 0; i < 3; i = i + 1)
        pts[i] = Pt.make(i);
    Pt* d = Pt.make(10);
    pts[pick()] += d;
    pts[pick()] += d;
    Stdio.printf("pts %d %d %d picks %d\n", pts[0].x, pts[1].x, pts[2].x, picks);
    for (i32 i = 0; i < 3; i = i + 1)
        pts[i] = 0;
    d = 0;
    shared = 0;
    Stdio.printf("live %d\n", live);
    return 0;
    }
