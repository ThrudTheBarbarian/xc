// method_call — a virtual method call per iteration.
// Exercises: dispatch cost, inlining across a method boundary.
#import "Stdio.xc"
#import "include/bench_time.xc"

class Shape      { u32 k; void init(u32 x) { k = x; } u32 score(void) { return k; } }
class Boxy : Shape
    {
    void init(u32 x) { super.init(x); }
    u32 score(void)  { return k + (u32)1; }
    }

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    Shape* s = new Boxy(seed);
    u32 acc = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)1600000000; r++) acc = acc + s.score() + r;
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
