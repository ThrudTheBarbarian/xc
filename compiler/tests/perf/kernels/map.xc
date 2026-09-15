// map.xc — elementwise map then reduce.
// Exercises: store loops (pointer-IV writing), read loops, mixed-width arithmetic.
// See reduce.xc for the -DBENCH argc-seed / u32-accumulator convention.
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
    u16 a[64];
    u16 b[64];
    for (i32 i = 0; i < 64; i++)
        a[i] = (u16)((i * 3 + seed) & $FFFF);

    for (i32 rep = 0; rep < REPS; rep++)
        {
        for (i32 i = 0; i < 64; i++)
            b[i] = (u16)((a[i] * 5 + 7) & $FFFF);
        for (i32 i = 0; i < 64; i++)
            acc += b[i];
        }

#ifdef BENCH
    Stdio.printf("%lu\n", acc);
    return 0;
#else
    Stdio.printf("%ld\n", acc);
#endif
    }
