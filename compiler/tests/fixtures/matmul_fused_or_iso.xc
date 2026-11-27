//xtc-flags: target=arm64
//xtc-na: x86_64,win64,arm9,m68k,xt6502,wasm32 — arm64 fuses the nest; x86-64 does not (matmul_exact_x86.xc)
// matmul_fused_or_iso.xc — the same matrix multiply three ways on arm64: as
// written (the nest fuses, #569, and the SME or NEON kernel runs), under
// :goal(speed) (the `_fast` kernel), and under an explicit :goal(accuracy),
// which is strict ISO: no kernel and nothing fused. Each element is
// -c*1 + a*a with c = a*a rounded, so a fused chain keeps the product's low
// bits (2^-24 for f32, 2^-54 for f64) and the unfused sum is 0. 16x16 runs
// the kernel's register blocks, 11x9 its edges.
// private:docs/Design/neon-matmul.md.
#import "Stdio.xc"
void mmDefault(float* a, float* b, float* c, u32 m, u32 n, u32 kk)
    {
    for (u32 i = 0; i < m; i++)
        for (u32 j = 0; j < n; j++)
            {
            float s = 0.0;
            for (u32 k = 0; k < kk; k++)
                s = s + a[i * kk + k] * b[k * n + j];
            c[i * n + j] = s;
            }
    }
void mmSpeed(float* a, float* b, float* c, u32 m, u32 n, u32 kk)
    {
    for (u32 i = 0; i < m; i++) :goal(speed)
        for (u32 j = 0; j < n; j++)
            {
            float s = 0.0;
            for (u32 k = 0; k < kk; k++)
                s = s + a[i * kk + k] * b[k * n + j];
            c[i * n + j] = s;
            }
    }
void mmAccuracy(float* a, float* b, float* c, u32 m, u32 n, u32 kk)
    {
    for (u32 i = 0; i < m; i++) :goal(accuracy)
        for (u32 j = 0; j < n; j++)
            {
            float s = 0.0;
            for (u32 k = 0; k < kk; k++)
                s = s + a[i * kk + k] * b[k * n + j];
            c[i * n + j] = s;
            }
    }
void dmDefault(double* a, double* b, double* c, u32 m, u32 n, u32 kk)
    {
    for (u32 i = 0; i < m; i++)
        for (u32 j = 0; j < n; j++)
            {
            double s = 0.0d;
            for (u32 k = 0; k < kk; k++)
                s = s + a[i * kk + k] * b[k * n + j];
            c[i * n + j] = s;
            }
    }
void dmAccuracy(double* a, double* b, double* c, u32 m, u32 n, u32 kk)
    {
    for (u32 i = 0; i < m; i++) :goal(accuracy)
        for (u32 j = 0; j < n; j++)
            {
            double s = 0.0d;
            for (u32 k = 0; k < kk; k++)
                s = s + a[i * kk + k] * b[k * n + j];
            c[i * n + j] = s;
            }
    }
// every element's bits, or "mixed" when they differ
void report32(u8* what, float* c, u32 count)
    {
    u32* cb = (u32*)c;
    bool same = true;
    for (u32 i = 1; i < count; i++)
        if (cb[i] != cb[0])
            same = false;
    if (same)
        Stdio.printf("%s %08x\n", what, cb[0]);
    else
        Stdio.printf("%s mixed\n", what);
    }
void report64(u8* what, double* c, u32 count)
    {
    u64* cb = (u64*)c;
    bool same = true;
    for (u32 i = 1; i < count; i++)
        if (cb[i] != cb[0])
            same = false;
    if (same)
        Stdio.printf("%s %016llx\n", what, cb[0]);
    else
        Stdio.printf("%s mixed\n", what);
    }
void run(u32 m, u32 n)
    {
    u32 kk = 2;
    float* a = new float[m * kk]; float* b = new float[kk * n]; float* c = new float[m * n];
    u32* ab = (u32*)a; u32* bb = (u32*)b;
    for (u32 i = 0; i < m; i++)
        {
        ab[i * kk] = $BF801000;             // -(1 + 2^-11)
        ab[i * kk + 1] = $3F800800;         // 1 + 2^-12
        }
    for (u32 j = 0; j < n; j++)
        {
        bb[j] = $3F800000;                  // 1
        bb[n + j] = $3F800800;              // 1 + 2^-12
        }
    Stdio.printf("%ux%u\n", m, n);
    mmDefault(a, b, c, m, n, kk);
    report32("  f32 default ", c, m * n);
    mmSpeed(a, b, c, m, n, kk);
    report32("  f32 speed   ", c, m * n);
    mmAccuracy(a, b, c, m, n, kk);
    report32("  f32 accuracy", c, m * n);
    double* a2 = new double[m * kk]; double* b2 = new double[kk * n]; double* c2 = new double[m * n];
    u64* ab2 = (u64*)a2; u64* bb2 = (u64*)b2;
    for (u32 i = 0; i < m; i++)
        {
        ab2[i * kk] = $BFF0000004000000;    // -(1 + 2^-26)
        ab2[i * kk + 1] = $3FF0000002000000; // 1 + 2^-27
        }
    for (u32 j = 0; j < n; j++)
        {
        bb2[j] = $3FF0000000000000;         // 1
        bb2[n + j] = $3FF0000002000000;     // 1 + 2^-27
        }
    dmDefault(a2, b2, c2, m, n, kk);
    report64("  f64 default ", c2, m * n);
    dmAccuracy(a2, b2, c2, m, n, kk);
    report64("  f64 accuracy", c2, m * n);
    delete a; delete b; delete c; delete a2; delete b2; delete c2;
    }
i32 main(void)
    {
    run(16, 16);
    run(11, 9);
    return 0;
    }
