// matrix_mul — multiply two small square matrices, repeatedly.
// Exercises: triple-nested loops, strided addressing, accumulation.
#import "Stdio.xc"
#define M 32
i32 main(i32 argc, u8** argv)
    {
    u32 a[M * M]; u32 b[M * M]; u32 c[M * M];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)(M * M); i++)
        { a[i] = (i + seed) & (u32)15; b[i] = (i ^ seed) & (u32)15; }
    for (u32 r = (u32)0; r < (u32)200; r++)
        for (u32 i = (u32)0; i < (u32)M; i++)
            for (u32 j = (u32)0; j < (u32)M; j++)
                {
                u32 s = (u32)0;
                for (u32 k = (u32)0; k < (u32)M; k++)
                    s = s + (a[i * (u32)M + k] * b[k * (u32)M + j]);
                c[i * (u32)M + j] = s + r;
                }
    u32 acc = (u32)0;
    for (u32 i = (u32)0; i < (u32)(M * M); i++) acc = acc + c[i];
    Stdio.printf("%lu\n", acc);
    return 0;
    }
