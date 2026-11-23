// Operators on a class returned BY VALUE: each `plus` builds its result on
// the stack and returns it through the caller's result slot. In `a + b + c`
// each intermediate gets its own slot in the caller's frame, comes apart at
// the end of the full expression, and releases what it holds.
//
// Every Vec instance holds a Tracker, and both classes count themselves from
// init to dealloc, so a leaked or doubly released intermediate shows up in
// `live` (instances) or `tracked` (the objects they hold). The class's static
// storage is an instance too, made by the first static call; `ready` makes it
// before anything is counted.
#import <Stdio.xc>

i32 live;
i32 tracked;

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
    void init(void) { live = live + 1; t = new Tracker(); }
    void dealloc(void) { live = live - 1; }
    Vec plus(Vec o)  :operator(self + o) { Vec r; r.x = x + o.x; r.y = y + o.y; return r; }
    Vec minus(Vec o) :operator(self - o) { Vec r; r.x = x - o.x; r.y = y - o.y; return r; }
    Vec times(i32 k) :operator(self * k) { Vec r; r.x = x * k; r.y = y * k; return r; }
    Vec negated()    :operator(-self)    { Vec r; r.x = 0 - x; r.y = 0 - y; return r; }
    static Vec scaled(i32 k, Vec v) :operator(k * v) { return v.times(k); }
    i32 dot(Vec o)   :operator(self ^ o) { return x * o.x + y * o.y; }
    static void ready(void) { }
    }

void show(string label, Vec v)
    {
    Stdio.printf("%s %d %d\n", label, v.x, v.y);
    }

i32 sum3(void)
    {
    Vec a;
    a.x = 1;
    a.y = 2;
    Vec b;
    b.x = 10;
    b.y = 20;
    Vec c;
    c.x = 100;
    c.y = 200;
    Vec s = a + b + c;
    show("sum", s);
    show("chain", a + b * 2 - -c);
    show("left", 3 * a);
    show("direct", a + b + c + a);
    Stdio.printf("dot %d\n", a ^ b);
    Stdio.printf("inside live %d tracked %d\n", live, tracked);
    return s.x + s.y;
    }

i32 main(void)
    {
    Vec.ready();
    live = 0;
    tracked = 0;
    i32 r = sum3();
    Stdio.printf("r %d\n", r);
    Stdio.printf("live %d tracked %d\n", live, tracked);
    for (i32 i = 0; i < 4; i = i + 1)
        {
        Vec p;
        p.x = i;
        p.y = i * 2;
        Vec q = p + p + p;
        Stdio.printf("loop %d %d\n", q.x, q.y);
        }
    Stdio.printf("live %d tracked %d\n", live, tracked);
    return 0;
    }
