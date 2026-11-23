// A `+1` object that one arm of `?:` makes and does not yield (the receiver of
// a method call, a call's argument) comes apart at the end of that arm, on the
// only path that made it. An arm whose value IS a temporary hands it to the
// ternary's result, and an arm whose value was read out of a temporary keeps
// it alive. `live` counts Probes from init to dealloc, so a leak shows as a
// count left over and an early release as a count gone short (or a crash).
#import <Foundation.xc>
#import <Stdio.xc>

i32 live;

class Probe
    {
    u32 v;
    void init(u32 x) { v = x; live = live + 1; }
    void dealloc(void) { live = live - 1; }
    u32 val(void) { return v; }
    bool odd(void) { return (v & (u32)1) == (u32)1; }
    }

class Holder
    {
    Probe* p;
    void init(u32 x) { p = new Probe(x); }
    Probe* get(void) { return p; }
    }

Probe* make(u32 i) { return new Probe(i); }
Holder* hold(u32 i) { return new Holder(i); }
u32 twice(Probe* p) { return p.val() * (u32)2; }

i32 main(void)
    {
    u32 n = (u32)0;
    bool c = true;
    for (u32 i = (u32)0; i < (u32)100; i = i + (u32)1)
        n = n + (c ? make(i).val() : (u32)0);
    Stdio.printf("receiver %u live %d\n", n, live);

    Array* a = new Array();
    for (u32 i = (u32)0; i < (u32)10; i = i + (u32)1)
        a.add((Object*)Number.with(i));
    n = (u32)0;
    for (u32 i = (u32)0; i < (u32)12; i = i + (u32)1)
        n = n + (i < a.count() ? ((Number*)a.get(i)).asU32() : (u32)0);
    Stdio.printf("element %u\n", n);

    n = (u32)0;
    for (u32 i = (u32)0; i < (u32)10; i = i + (u32)1)
        n = n + (i < (u32)5 ? twice(make(i)) : twice(make(i + (u32)100)));
    Stdio.printf("both arms %u live %d\n", n, live);

    n = (u32)0;
    for (u32 i = (u32)0; i < (u32)10; i = i + (u32)1)
        n = n + (c ? (make(i).odd() ? make(i).val() : (u32)1000) : make((u32)7).val());
    Stdio.printf("nested %u live %d\n", n, live);

    n = (u32)0;
    for (u32 i = (u32)0; i < (u32)10; i = i + (u32)1)
        n = n + (make(i).odd() ? (u32)1 : make(i).val());
    Stdio.printf("condition %u live %d\n", n, live);

        {
        Probe* x = c ? make((u32)1) : make((u32)2);
        Probe* y = !c ? make((u32)3) : make((u32)4);
        Stdio.printf("value %u %u live %d\n", x.val(), y.val(), live);
        Probe* z = c ? hold((u32)5).get() : x;
        Stdio.printf("read out %u live %d\n", z.val(), live);
        u32 m = (c ? make((u32)6) : x).val();
        Stdio.printf("mixed %u live %d\n", m, live);
        }
    Stdio.printf("end live %d\n", live);
    return 0;
    }
