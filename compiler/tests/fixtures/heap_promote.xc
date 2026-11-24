// heap_promote.xc — a stack instance whose address is taken lives on the
// heap (#604). gLive counts the instances made by init and not yet gone.
//
//   T1  `&y` stored in a container outlives y's scope, and goes when the
//       container drops it
//   T2  a weak pointer to y is cleared when y's scope ends
//   T3  `&y` passed to a strong parameter and dropped: dealloc runs once, at
//       y's scope exit
//   T4  `return &y;` hands the caller the instance, which it releases
//   T5  y keeps its value semantics: copy out, assign in, method calls and
//       member writes
//   T6  a loop: each iteration's instance, with continue and break
//   T7  returned by value, it is copied out and the heap instance goes
//
// heap_promote_forms.xc has the places `&y` can be stored.

#import "Stdio.xc"
#import "Array.xc"

i32 gLive = 0;

class P : Object
    {
    i32 a;
    i32 b;
    void init(void) { gLive = gLive + 1; }
    void dealloc(void) { gLive = gLive - 1; }
    i32 sum(void) { return a + b; }
    void bump(void) { a = a + 1; }
    }

// No counter: a copy runs no init, so it would skew gLive.
class V : Object
    {
    i32 a;
    i32 b;
    i32 sum(void) { return a + b; }
    void bump(void) { a = a + 1; }
    }

weak:P* gWeak;
i32 gDeallocs = 0;

class Counted : Object
    {
    i32 v;
    void dealloc(void) { gDeallocs = gDeallocs + 1; }
    }

void store(Array* arr)
    {
    P y;
    y.a = 1;
    y.b = 2;
    arr.add(&y);
    }

void watch(void)
    {
    P y;
    y.a = 5;
    gWeak = &y;
    Stdio.printf("T2 in scope %d\n", gWeak != nil);
    }

i32 peek(Counted* c) { return c.v; }

P* make(i32 a)
    {
    P y;
    y.a = a;
    return &y;
    }

P copyOut(void)
    {
    P y;
    y.a = 8;
    y.b = 9;
    weak:P* w = &y;
    w.b = 10;
    return y;
    }

i32 main(void)
    {
    Array* arr = new Array();
    store(arr);
    P* first = (P*)arr.get(0);
    Stdio.printf("T1 kept %d live %d\n", first.sum(), gLive);
    first = nil;
    arr.removeAll();
    Stdio.printf("T1 dropped live %d\n", gLive);

    watch();
    Stdio.printf("T2 after scope %d live %d\n", gWeak != nil, gLive);

        {
        Counted c;
        c.v = 4;
        Stdio.printf("T3 peek %d deallocs %d\n", peek(&c), gDeallocs);
        }
    Stdio.printf("T3 deallocs %d\n", gDeallocs);

    P* m = make(6);
    Stdio.printf("T4 a %d live %d\n", m.a, gLive);
    m = nil;
    Stdio.printf("T4 released live %d\n", gLive);

        {
        V z;
        V* pz = &z;
        z.a = 3;
        z.b = 4;
        V c = z;
        c.a = 30;
        Stdio.printf("T5 copy %d %d, z %d %d\n", c.a, c.b, z.a, pz.a);
        z = c;
        z.bump();
        Stdio.printf("T5 assign %d %d sum %d via pointer %d\n", z.a, z.b, z.sum(), pz.a);
        }

    i32 n = 0;
    for (i32 i = 0; i < 5; i = i + 1)
        {
        P y;
        y.a = i;
        if (i == 1)
            continue;
        if (i == 3)
            break;
        arr.add(&y);
        n = n + 1;
        }
    Stdio.printf("T6 kept %d live %d\n", n, gLive);
    arr.removeAll();
    Stdio.printf("T6 dropped live %d\n", gLive);

    P v = copyOut();
    Stdio.printf("T7 %d %d live %d\n", v.a, v.b, gLive);
    return 0;
    }
