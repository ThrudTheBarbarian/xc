// arc_alloc — allocate an object per iteration and let ARC free it.
// Exercises: heap allocation, retain/release traffic, method dispatch.
// Each object outlives its iteration (it is kept until the next one replaces
// it), so no compiler can put it on the stack or fold the loop away, and the
// result is folded in with ^ so the sum has no closed form.
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
    Node* keep = new Node(seed);
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)80000000; r++)
        {
        Node* n = new Node(r + seed);
        acc = (acc ^ n.get()) + keep.get();
        keep = n;
        }
    i64 t1 = bench_now_us();
    Stdio.printf("%lu %lld\n", acc, t1 - t0);
    return 0;
    }
