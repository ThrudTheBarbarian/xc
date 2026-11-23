// The core of class_value_member, small enough for every target: an instance
// held by value inside another is laid out in place, set up with its owner
// (stack or heap), torn down with it, and copied with it. `live` counts
// Trackers from init to dealloc, so a leak or a double release shows.
#import <Stdio.xc>

i32 live;

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
    }

class Deep
    {
    i32 a;
    Outer mid;
    }

class Named
    {
    Tracker* t;
    i32 n;
    void init(void) { t = new Tracker(); n = 7; }
    }

class Box
    {
    i32 tag;
    Named m;
    }

i32 main(void)
    {
    Outer o;
    o.k = 1;
    o.inner.v = 5;
    Stdio.printf("issue %d %d\n", o.k, o.inner.v);
    Deep d;
    d.mid.inner.v = 3;
    Stdio.printf("deep %d\n", d.mid.inner.v);
        {
        Box b;
        Stdio.printf("stack n %d live %d\n", b.m.n, live);
        Box c = b;
        b.m.t = new Tracker();
        Stdio.printf("copy live %d\n", live);
        }
    Stdio.printf("stack scope live %d\n", live);
        {
        Box* h = new Box();
        Stdio.printf("heap n %d live %d\n", h.m.n, live);
        h = (Box*)0;
        Stdio.printf("heap gone live %d\n", live);
        }
    return 0;
    }
