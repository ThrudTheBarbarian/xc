//xtc-flags: target=arm64 --par-auto
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc)
// par_step.xc — a `par` loop with a stride (`step s`, a literal above 1):
// the work items are its iterations, counted from 0, with i = a + k*s. A
// written block, an inclusive range, an empty range, and a plain step loop
// that --par-auto makes a block. The answers are a serial loop's.
#import "Stdio.xc"
#import "Par.xc"
#define N 100003
u32 a[N];
u32 b[N];
i32 main(void)
    {
    u32 start = (u32)5;
    par evens
        {
        for (u32 i in start..N step 2)
            a[i] = i * (u32)3;
        }
    u32 sum = (u32)0;
    par :reduce(+ sum)
        {
        for (u32 i in 0...N - 1 step 7)
            sum = sum + a[i] + i;
        }
    u32 none = (u32)0;
    u32 top = (u32)4;
    par :reduce(+ none)
        {
        for (u32 i in 10..top step 3)
            none = none + (u32)1;
        }
    for (u32 i in 1..N step 4)
        b[i] = a[i] + (u32)1;
    u32 check = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1)
        check = check * (u32)31 + a[i] + b[i];
    Stdio.printf("a[5]=%u a[6]=%u a[N-2]=%u sum=%u none=%u b[5]=%u check=%u\n",
                 a[5], a[6], a[N - 2], sum, none, b[5], check);
    return 0;
    }
