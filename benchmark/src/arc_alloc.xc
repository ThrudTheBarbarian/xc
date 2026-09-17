// arc_alloc — allocate an object per iteration and let ARC free it.
// Exercises: heap allocation, retain/release traffic, method dispatch.
#import "Stdio.xc"
#import "include/bench_time.xc"

class Node
    {
    u32 v;
    void init(u32 x) { v = x; }
    u32 get(void)    { return v; }
    }

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    u32 acc  = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)2000000; r++)
        {
        Node* n = new Node(r + seed);
        acc = acc + n.get();
        }
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
