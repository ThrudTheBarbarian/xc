// accum.xc — NON-tail accumulator recursion (the add is AFTER the self-call,
// so convertsTailRecursion does NOT apply; convertsAccumulatorRecursion does).
// The in-order backends (m68k, xt6502) should win from turning the recursion
// into an in-place accumulator loop (no per-level prologue/epilogue/return).
#import <Stdio.xc>
#ifndef REPS
#define REPS 400
#endif

i32 rsum(i32 n)
    {
    if (n <= 0)
        return 0;
    return n + rsum(n - 1);
    }

#ifdef BENCH
i32 main(i32 argc, u8** argv)
    {
    i32 seed = argc;
    u32 sum = 0;
#else
void main(void)
    {
    i32 seed = 0;
    i32 sum = 0;
#endif
    for (i32 rep = 0; rep < REPS; rep++)
        sum += rsum(60 + (seed & 1));

#ifdef BENCH
    Stdio.printf("%lu\n", sum);
    return 0;
#else
    Stdio.printf("%ld\n", sum);
#endif
    }
