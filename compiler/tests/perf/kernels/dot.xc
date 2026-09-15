// dot.xc — two-array multiply-accumulate.
// Exercises: two simultaneous array walks (the pointer-IV pass caps at 2 bases),
// 16x16 multiply, wide accumulation. See reduce.xc for the -DBENCH convention.
// Products stay < 65536 so xtc's u16-wrap multiply and C's int multiply agree.
#import <Stdio.xc>
#ifndef REPS
#define REPS 400
#endif

#ifdef BENCH
i32 main(i32 argc, u8** argv)
    {
    i32 seed = argc;
    u32 acc = 0;
#else
void main(void)
    {
    i32 seed = 0;
    i32 acc = 0;
#endif
    u16 a[48];
    u16 b[48];
    for (i32 i = 0; i < 48; i++)
        {
        a[i] = (u16)((i + 1 + seed) & $FFFF);
        b[i] = (u16)((i * 2 + 1) & $FFFF);
        }

    for (i32 rep = 0; rep < REPS; rep++)
        for (i32 i = 0; i < 48; i++)
            acc += a[i] * b[i];

#ifdef BENCH
    Stdio.printf("%lu\n", acc);
    return 0;
#else
    Stdio.printf("%ld\n", acc);
#endif
    }
