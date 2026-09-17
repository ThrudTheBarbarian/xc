// poly_dispatch — dispatch through a mixed array of subclasses.
// Exercises: virtual dispatch the compiler cannot devirtualise.
#import "Stdio.xc"
#define N 256
class Op       { u32 k; void init(u32 x) { k = x; } u32 apply(u32 v) { return v + k; } }
class OpMul : Op { void init(u32 x) { super.init(x); } u32 apply(u32 v) { return v * (k | (u32)1); } }
class OpXor : Op { void init(u32 x) { super.init(x); } u32 apply(u32 v) { return v ^ k; } }
i32 main(i32 argc, u8** argv)
    {
    Op* ops[N]; u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++)
        {
        if ((i % (u32)3) == (u32)0)      ops[i] = new Op(i + seed);
        else if ((i % (u32)3) == (u32)1) ops[i] = new OpMul(i + seed);
        else                             ops[i] = new OpXor(i + seed);
        }
    u32 acc = (u32)1;
    for (u32 r = (u32)0; r < (u32)20000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++) acc = ops[i].apply(acc) + r;
    Stdio.printf("%lu\n", acc);
    return 0;
    }
