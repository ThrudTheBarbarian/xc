// heap_promote_forms.xc — every place `&y` of a local stack instance can be
// stored, now that y moves to the heap (#604): a strong local's initialiser
// (auto too), an assignment to a strong local, field or global, a weak local,
// a strong parameter, and a return. gLive counts instances made by init and
// not yet gone; each line shows the instance still reachable, then gone.

#import "Stdio.xc"

i32 gLive = 0;

class P : Object
    {
    i32 a;
    i32 b;
    void init(void) { gLive = gLive + 1; }
    void dealloc(void) { gLive = gLive - 1; }
    }

class Box { u8 v; }

P* gLast;

class Holder : Object
    {
    P* last;
    void keep(void)
        {
        P y;
        y.a = 2;
        last = &y;
        }
    }

void keepGlobal(void)
    {
    P y;
    y.a = 3;
    gLast = &y;
    }

P* give(void)
    {
    P y;
    y.a = 4;
    return &y;
    }

void sink(Box* b) { b.v = 1; }

i32 main(void)
    {
    P* outer = nil;
        {
        P y;
        y.a = 1;
        P* r = &y;
        auto q = &y;
        P* s = nil;
        s = &y;
        weak:P* w = &y;
        outer = r;
        Stdio.printf("locals %d %d %d %d live %d\n", r.a, q.a, s.a, w.a, gLive);
        }
    Stdio.printf("outlives its scope %d live %d\n", outer.a, gLive);
    outer = nil;
    Stdio.printf("released live %d\n", gLive);

    Holder* h = new Holder();
    h.keep();
    Stdio.printf("field %d live %d\n", h.last.a, gLive);
    h = nil;
    Stdio.printf("field released live %d\n", gLive);

    keepGlobal();
    Stdio.printf("global %d live %d\n", gLast.a, gLive);
    gLast = nil;
    Stdio.printf("global released live %d\n", gLive);

    P* g = give();
    Stdio.printf("returned %d live %d\n", g.a, gLive);
    g = nil;
    Stdio.printf("returned released live %d\n", gLive);

    Box bx;
    sink(&bx);
    Stdio.printf("box %d\n", bx.v);
    return 0;
    }
