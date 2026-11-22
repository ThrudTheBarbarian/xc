// The core of stack_class_arc, small enough for every target: a stack
// instance's dealloc runs at each exit from its scope, a copy retains, an
// assignment releases the old references, a by-value return moves, and an
// unadopted by-value result comes apart after its statement. `live` counts
// Trackers from init to dealloc, so a leak or a double release shows.
#import <Stdio.xc>

i32 live;

class Tracker
    {
    i32 id;
    void init(void) { live = live + 1; }
    void dealloc(void) { live = live - 1; }
    }

class Holder
    {
    Tracker* t;
    i32 n;
    void dealloc(void) { Stdio.printf("  dealloc %d\n", n); }
    }

Holder mk(i32 k)
    {
    Holder h;
    h.t = new Tracker();
    h.n = k;
    return h;
    }

i32 early(i32 k)
    {
    Holder h;
    h.t = new Tracker();
    h.n = 50 + k;
    if (k > 0)
        return k;
    return 0;
    }

i32 main(void)
    {
    for (i32 i = 0; i < 3; i++)
        {
        Holder h;
        h.t = new Tracker();
        h.n = i;
        if (i == 1)
            continue;
        }
    Stdio.printf("loop live %d\n", live);
        {
        Holder a = mk(10);
        Holder b = a;
        b.n = 11;
        a.t = new Tracker();
        Stdio.printf("copy live %d\n", live);
        b = mk(12);
        Stdio.printf("assign live %d\n", live);
        }
    Stdio.printf("scope live %d\n", live);
    Stdio.printf("early %d\n", early(1));
    Stdio.printf("temp %d\n", mk(20).n);
    Stdio.printf("end live %d\n", live);
    return 0;
    }
