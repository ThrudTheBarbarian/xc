//xtc-flags: target=arm64
//xtc-na: x86_64,win64 — arm64's own hashes (fused multiply-add); matmul_exact_x86.xc is the x86-64 one
// sme_matmul_exact.xc — a dense matrix multiply, f32 and f64, over 16 shapes
// with row strides wider than the rows, and inputs dense in infinities, signed
// zeros and denormals. On arm64 macOS the SME matrix kernel does the work
// (idiom-matmul); the results must be the loop's, bit for bit, which the
// hashes pin. A NaN input sends the kernel back to the loop, so the NaN keeps
// its payload (nanCase). private:docs/Design/simd-sme-plan.md.
#import "Stdio.xc"
void gemm32(float* a, float* b, float* c, u32 m, u32 n, u32 kk, u32 lda, u32 ldb, u32 ldc)
    {
    for (u32 i = (u32)0; i < m; i++)
        for (u32 j = (u32)0; j < n; j++)
            {
            float s = 0.0;
            for (u32 k = (u32)0; k < kk; k++)
                s = s + a[i * lda + k] * b[k * ldb + j];
            c[i * ldc + j] = s;
            }
    }
void gemm64(double* a, double* b, double* c, u32 m, u32 n, u32 kk, u32 lda, u32 ldb, u32 ldc)
    {
    for (u32 i = (u32)0; i < m; i++)
        for (u32 j = (u32)0; j < n; j++)
            {
            double s = 0.0d;
            for (u32 k = (u32)0; k < kk; k++)
                s = s + a[i * lda + k] * b[k * ldb + j];
            c[i * ldc + j] = s;
            }
    }
u32 rng(u32* st)
    {
    u32 x = *st;
    x = x ^ (x << (u32)13); x = x ^ (x >> (u32)17); x = x ^ (x << (u32)5);
    *st = x;
    return x;
    }
// raw bits: mostly ordinary values, sometimes a special one
u32 bits32(u32* st)
    {
    u32 r = rng(st);
    u32 sel = r % (u32)8;
    if (sel == (u32)0) return (u32)$00000000;       // quiet NaN with a payload
    if (sel == (u32)1) return (u32)$00000123;       // denormal
    if (sel == (u32)2) return (u32)$80000000;       // -0
    if (sel == (u32)3) return (u32)$7F800000;       // +inf
    if (sel == (u32)4) return (u32)$80654321;       // negative denormal
    u32 e = (u32)110 + (rng(st) % (u32)36);         // exponents near 1
    return (rng(st) & (u32)$807FFFFF) | (e << (u32)23);
    }
u64 bits64(u32* st)
    {
    u32 r = rng(st);
    u32 sel = r % (u32)8;
    if (sel == (u32)0) return (u64)$0000000000000000;
    if (sel == (u32)1) return (u64)$0000000000012345;
    if (sel == (u32)2) return (u64)$8000000000000000;
    if (sel == (u32)3) return (u64)$FFF0000000000000;
    u64 e = (u64)(1000 + (rng(st) % (u32)40));
    u64 m = ((u64)rng(st) << (u64)32 | (u64)rng(st)) & (u64)$800FFFFFFFFFFFFF;
    return m | (e << (u64)52);
    }
void nanCase(void)
    {
    float* a = new float[4]; float* b = new float[4]; float* c = new float[4];
    u32* ab = (u32*)a; u32* bb = (u32*)b; u32* cb = (u32*)c;
    // c[0][0] = a0*b0 + a1*b2 ; c[0][1] = a0*b1 + a1*b3 ; ...
    ab[0] = (u32)$7FC01234; ab[1] = (u32)$3F800000; ab[2] = (u32)$40000000; ab[3] = (u32)$40400000;
    bb[0] = (u32)$3F800000; bb[1] = (u32)$7FC0BEEF; bb[2] = (u32)$40000000; bb[3] = (u32)$FFC05555;
    gemm32(a, b, c, (u32)2, (u32)2, (u32)2, (u32)2, (u32)2, (u32)2);
    Stdio.printf("%08x %08x %08x %08x\n", cb[0], cb[1], cb[2], cb[3]);
    }

i32 main(i32 argc, u8** argv)
    {
    u32 st = (u32)12345;
    u32 shapes[48] = {1,1,1, 1,17,3, 17,1,5, 16,16,16, 17,33,9, 31,15,64, 64,64,1, 5,7,0,
                      33,47,100, 100,37,211, 8,9,10, 65,3,129, 3,65,2, 128,128,128, 2,200,7, 40,40,40};
    for (u32 t = (u32)0; t < (u32)16; t++)
        {
        u32 m = shapes[t * (u32)3]; u32 n = shapes[t * (u32)3 + (u32)1]; u32 kk = shapes[t * (u32)3 + (u32)2];
        u32 pad = t % (u32)3;               // strides wider than the rows
        u32 lda = kk + pad; u32 ldb = n + pad * (u32)2; u32 ldc = n + pad;
        u32 asz = m * lda + (u32)1; u32 bsz = (kk + (u32)1) * ldb + (u32)1; u32 csz = m * ldc + (u32)1;
        float* a = new float[asz]; float* b = new float[bsz]; float* c = new float[csz];
        u32* ab = (u32*)a; u32* bb = (u32*)b; u32* cb = (u32*)c;
        for (u32 i = (u32)0; i < asz; i++) ab[i] = bits32(&st);
        for (u32 i = (u32)0; i < bsz; i++) bb[i] = bits32(&st);
        for (u32 i = (u32)0; i < csz; i++) cb[i] = (u32)$DEADBEEF;
        gemm32(a, b, c, m, n, kk, lda, ldb, ldc);
        u32 h = (u32)2166136261;
        for (u32 i = (u32)0; i < csz; i++) h = (h ^ cb[i]) * (u32)16777619;
        double* a2 = new double[asz]; double* b2 = new double[bsz]; double* c2 = new double[csz];
        u64* ab2 = (u64*)a2; u64* bb2 = (u64*)b2; u64* cb2 = (u64*)c2;
        for (u32 i = (u32)0; i < asz; i++) ab2[i] = bits64(&st);
        for (u32 i = (u32)0; i < bsz; i++) bb2[i] = bits64(&st);
        for (u32 i = (u32)0; i < csz; i++) cb2[i] = (u64)$DEADBEEFDEADBEEF;
        gemm64(a2, b2, c2, m, n, kk, lda, ldb, ldc);
        u64 h2 = (u64)1469598103934665603;
        for (u32 i = (u32)0; i < csz; i++) h2 = (h2 ^ cb2[i]) * (u64)1099511628211;
        Stdio.printf("%2u %3ux%3ux%3u f32 %08x f64 %016llx\n", t, m, n, kk, h, h2);
        delete a; delete b; delete c; delete a2; delete b2; delete c2;
        }
    nanCase();
    return 0;
    }
