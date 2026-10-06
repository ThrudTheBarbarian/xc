// matrix_mul_f32 — multiply two float matrices, repeatedly.
// Exercises: a dense float matrix multiply (SME outer products on arm64 macOS
// with SME; NEON or SSE elsewhere). The values are small integers, so every
// product and sum is exact and the checksum is the same in every language,
// whether or not it fuses a*b + s.
#import "Stdio.xc"
#import "include/bench_time.xc"
#define M 128
i32 main(i32 argc, u8** argv)
    {
    float* a = new float[M * M];
    float* b = new float[M * M];
    float* c = new float[M * M];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)(M * M); i++)
        { a[i] = (float)((i + seed) & (u32)15); b[i] = (float)((i ^ seed) & (u32)15); }
    u32 acc = (u32)0;
    i64 t0 = bench_now_us();
    for (u32 r = (u32)0; r < (u32)10000; r++)
        {
        a[r % (u32)(M * M)] = (float)(r & (u32)15);
        for (u32 i = (u32)0; i < (u32)M; i++)
            for (u32 j = (u32)0; j < (u32)M; j++)
                {
                float s = 0.0;
                for (u32 k = (u32)0; k < (u32)M; k++)
                    s = s + a[i * (u32)M + k] * b[k * (u32)M + j];
                c[i * (u32)M + j] = s;
                }
        acc = acc + (u32)c[(r * (u32)7919) % (u32)(M * M)];
        }
    for (u32 i = (u32)0; i < (u32)(M * M); i++) acc = acc + (u32)c[i];
    i64 t1 = bench_now_us();
    Stdio.printf("%u %lld\n", acc, t1 - t0);
    return 0;
    }
