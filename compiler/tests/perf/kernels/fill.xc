// fill.xc — constant array fill then reduce.
// Exercises: recognisesMemsetIdiom (for i: arr[i]=const → memset) and, for the
// sum-back, pointer-IV / LICM on a straight array walk. The fill loop is the
// memset proxy; the reduce is a non-collapsible (value depends on the fill).
#import <Stdio.xc>
#ifndef REPS
#define REPS 400
#endif

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
    u16 a[64];
    for (i32 rep = 0; rep < REPS; rep++)
        {
        for (i32 i = 0; i < 64; i++)
            a[i] = 0;
        a[seed & 1] = 7;
        for (i32 i = 0; i < 64; i++)
            sum += a[i];
        }

#ifdef BENCH
    Stdio.printf("%lu\n", sum);
    return 0;
#else
    Stdio.printf("%ld\n", sum);
#endif
    }
