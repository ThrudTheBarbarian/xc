//xtc-na: xt6502 — a by-value return of a class wider than 16 bytes; class_value_member_basic covers it there
// A class-typed ivar written without `*` (`Inner inner;`) is an instance laid
// out inside its owner. It is set up with the owner (its own vtable, its own
// init), torn down with it (its dealloc runs from the owner's), and copied with
// it, retaining what it refers to. `live` counts Trackers from init to dealloc,
// so a leak or a double release shows. A copy runs
// no init but is torn down, so deallocs ends four above inits.
#import <Stdio.xc>

i32 live;
i32 inits;
i32 deallocs;

class Tracker
    {
    i32 id;
    void init(void) { live = live + 1; }
    void dealloc(void) { live = live - 1; }
    }

class Inner { i32 v; }

class Outer
    {
    Inner inner;
    i32 k;
    i32 sum(void) { return k + inner.v; }
    }

class Deep
    {
    i32 a;
    Outer mid;
    i32 z;
    }

class Named
    {
    Tracker* t;
    i32 n;
    void init(void) { inits = inits + 1; t = new Tracker(); n = 7; }
    void dealloc(void) { deallocs = deallocs + 1; }
    }

class Box
    {
    i32 tag;
    Named m;
    Named* p;
    }

class Base
    {
    i32 x;
    i32 f(void) { return 1; }
    }

class Derived : Base
    {
    i32 f(void) { return 2 + x; }
    }

class Holder
    {
    u8 c;
    Derived d;
    i32 ask(void) { return d.f(); }
    }

Box makeBox(i32 tag)
    {
    Box b;
    b.tag = tag;
    return b;
    }

i32 main(void)
    {
    Outer o;
    o.k = 1;
    o.inner.v = 5;
    Stdio.printf("issue %d %d sum %d\n", o.k, o.inner.v, o.sum());

    Deep d;
    d.a = 1;
    d.mid.k = 2;
    d.mid.inner.v = 3;
    d.z = 4;
    Stdio.printf("deep %d %d %d %d\n", d.a, d.mid.k, d.mid.inner.v, d.z);
    Deep* hd = new Deep();
    hd.mid.inner.v = 9;
    hd.mid.k = 8;
    Stdio.printf("heap deep %d %d\n", hd.mid.inner.v, hd.mid.sum());

    Holder h;
    h.d.x = 40;
    Stdio.printf("vtable %d %d\n", h.ask(), h.d.f());

        {
        Box b;
        b.tag = 1;
        Stdio.printf("stack box n %d tag %d live %d\n", b.m.n, b.tag, live);
        b.m.t = new Tracker();
        Stdio.printf("replaced live %d\n", live);
        }
    Stdio.printf("stack scope live %d\n", live);

    for (i32 i = 0; i < 3; i++)
        {
        Box b;
        b.m.n = i;
        if (i == 1)
            continue;
        }
    Stdio.printf("loop live %d\n", live);

        {
        Box* hb = new Box();
        hb.p = new Named();
        Stdio.printf("heap box n %d live %d\n", hb.m.n, live);
        hb = (Box*)0;
        }
    Stdio.printf("heap scope live %d\n", live);

        {
        Box a;
        a.tag = 2;
        Box c = a;
        Stdio.printf("copy live %d same %d\n", live, a.m.t == c.m.t ? 1 : 0);
        a.m.t = new Tracker();
        Stdio.printf("copy split live %d tag %d\n", live, c.tag);
        Named x = a.m;
        x.n = 70;
        Stdio.printf("member copy %d %d live %d\n", x.n, a.m.n, live);
        c.m = x;
        Stdio.printf("member assign %d live %d\n", c.m.n, live);
        c.m = c.m;
        Stdio.printf("self assign %d live %d\n", c.m.n, live);
        }
    Stdio.printf("copy scope live %d\n", live);

        {
        Box r = makeBox(5);
        Stdio.printf("returned %d %d live %d\n", r.tag, r.m.n, live);
        Stdio.printf("temp %d\n", makeBox(6).m.n);
        Stdio.printf("temp live %d\n", live);
        }
    Stdio.printf("end live %d inits %d deallocs %d\n", live, inits, deallocs);
    return 0;
    }
