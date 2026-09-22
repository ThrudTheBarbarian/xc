// arc_array — hold objects in an array and walk them.
// Exercises: retain/release on stored references, field access through a pointer.
#import "Stdio.xc"
#import "include/bench_time.xc"
#define N 1024

class Cell { u32 v; void init(u32 x) { v = x; } u32 get(void) { return v; } }

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    Cell* cells[N];
    for (u32 i = (u32)0; i < (u32)N; i++) cells[i] = new Cell(i + seed);
    u32 acc = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)3000000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++) acc = acc + cells[i].get();
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
