// outer_vec_f32 — a float matrix multiply's j loop as f32 vectors (2026-10-30).
// The outer vectoriser took integer lanes only, and arrays rooted at a named
// local or a global; matrix_mul_f32's `new float[]` arrays and float sums kept
// it scalar wherever no matmul kernel replaced the loop (arm64 Linux, android,
// an arm64 Mac without SME): 15.3 s on a Raspberry Pi 5, against g++'s 4.2.
// Each lane is one j and does exactly its scalar operations in order, so the
// result is the scalar loop's bit for bit; the output is checked, and
// tests/driver/outer-vec-f32.sh checks the lane code.
#import "Stdio.xc"
#define M 16
i32 main(i32 argc, u8** argv)
{
    float* a = new float[M * M];
    float* b = new float[M * M];
    float* c = new float[M * M];
    for (u32 i = (u32)0; i < (u32)(M * M); i++)
        {
        a[i] = (float)((i * (u32)7) % (u32)13) * 0.25f;
        b[i] = (float)((i * (u32)5) % (u32)11) * 0.5f - 1.0f;
        }
    for (u32 i = (u32)0; i < (u32)M; i++)
        for (u32 j = (u32)0; j < (u32)M; j++)
            {
            float s = 0.0f;
            for (u32 k = (u32)0; k < (u32)M; k++)
                s = s + a[i * (u32)M + k] * b[k * (u32)M + j];
            c[i * (u32)M + j] = s;
            }
    double t = 0.0;
    for (u32 i = (u32)0; i < (u32)(M * M); i++)
        t = t + (double)c[i] * (double)(i + (u32)1);
    Stdio.printf("%.6f %.6f %.6f\n", (double)c[0], (double)c[M * M - 1], t);
    return 0;
}
