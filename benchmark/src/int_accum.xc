// int_accum — integer add and xor over an array.
// Exercises: loop induction, array addressing, u32 wraparound arithmetic.
//
// The array is seeded from argc so its contents are unknown at compile time,
// and the loop reads it every iteration. Without that both compilers reduce the
// whole loop to a closed form and the benchmark measures nothing.
#import "Stdio.xc"

#define N 4096

i32 main(i32 argc, u8** argv)
    {
    u32 a[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++)
        a[i] = (i * (u32)2654435761) + seed;

    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)20000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++)
            acc = acc + (a[i] ^ acc);

    Stdio.printf("%lu\n", acc);
    return 0;
    }
