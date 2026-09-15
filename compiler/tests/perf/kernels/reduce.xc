// reduce.xc — array-sum reduction kernel.
// Exercises: loop induction, array addressing / pointer-IV, accumulation.
//
// Default build: seed 0 (compile-time-constant array), i32 accumulator, %ld —
// this is what the simulators measure (deterministic checksum, cross-checked).
// -DBENCH build: seed from argc (runtime-opaque, so clang/gcc can't fold away
// the array loads) and a u32 accumulator (defined wraparound) so REPS can be
// cranked high enough for a stable wall-clock without signed overflow. Run with
// a fixed argument so the seed — and thus the checksum — is stable.
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
    for (i32 i = 0; i < 64; i++)
        a[i] = (u16)((i * 7 + 3 + seed) & $FFFF);

    for (i32 rep = 0; rep < REPS; rep++)
        for (i32 i = 0; i < 64; i++)
            sum += a[i];

#ifdef BENCH
    Stdio.printf("%lu\n", sum);
    return 0;
#else
    Stdio.printf("%ld\n", sum);
#endif
    }
