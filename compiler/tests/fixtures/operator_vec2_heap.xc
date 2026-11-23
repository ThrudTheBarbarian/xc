// Operators on a class whose results live on the heap. `:operator(pattern)`
// makes a method an operator; the method keeps its name. Precedence and
// associativity are the built-in ones: `a + b * 2.0 - -d` is
// a.plus(b.scaled(2.0)).minus(d.negated()). A static method puts the scalar
// on the left (`2.0 * a`). A relational operator returns what its method
// returns.
//
// Every intermediate result is a call result, released at the end of the full
// expression: `live` counts instances from init to dealloc, so a leaked or
// doubly released temporary shows as a count left over or gone negative.
#import <Stdio.xc>

i32 live;

class Vec2
    {
    float x;
    float y;
    void init(void) { live = live + 1; }
    void dealloc(void) { live = live - 1; }
    static Vec2* make(float a, float b) { Vec2* v = new Vec2(); v.x = a; v.y = b; return v; }
    Vec2* plus(Vec2* o)   :operator(self + o) { return Vec2.make(x + o.x, y + o.y); }
    Vec2* minus(Vec2* o)  :operator(self - o) { return Vec2.make(x - o.x, y - o.y); }
    Vec2* negated()       :operator(-self)    { return Vec2.make(-x, -y); }
    Vec2* scaled(float k) :operator(self * k) { return Vec2.make(x * k, y * k); }
    static Vec2* scaledBy(float k, Vec2* v) :operator(k * v) { return v.scaled(k); }
    bool less(Vec2* o)    :operator(self < o) { return x * x + y * y < o.x * o.x + o.y * o.y; }
    i32 tenths(void) { return (i32)(x * 10.0); }
    i32 tenthsY(void) { return (i32)(y * 10.0); }
    }

void show(string label, Vec2* v)
    {
    Stdio.printf("%s %d %d\n", label, v.tenths(), v.tenthsY());
    }

i32 main(void)
    {
    Vec2* a = Vec2.make(1.0, 2.0);
    Vec2* b = Vec2.make(3.0, 4.0);
    Vec2* d = Vec2.make(0.5, 0.25);
    show("chain", a + b * 2.0 - -d);
    show("left", 2.0 * a);
    show("neg", -a);
    show("named", a.plus(b));
    show("grouped", (a + b) * 3.0);
    Stdio.printf("less %d %d\n", a < b ? 1 : 0, b < a ? 1 : 0);
    if (a < b)
        Stdio.printf("a is shorter\n");
    Vec2* keep = a + b + d;
    show("keep", keep);
    keep = keep - a;
    show("again", keep);
    Stdio.printf("live %d\n", live);
    for (i32 i = 0; i < 3; i = i + 1)
        keep = keep + a;
    show("loop", keep);
    Stdio.printf("live %d\n", live);
    // A conditional whose arms are operators: the arm taken yields the value.
    Vec2* pick = a < b ? a + b : a - b;
    show("pick", pick);
    show("pick2", b < a ? a + b : a - b);
    pick = 0;
    Stdio.printf("live %d\n", live);
    keep = 0;
    a = 0;
    b = 0;
    d = 0;
    Stdio.printf("live %d\n", live);
    return 0;
    }
