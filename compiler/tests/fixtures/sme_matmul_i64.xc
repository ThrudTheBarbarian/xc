//xtc-flags: target=arm64
// sme_matmul_i64.xc — u64 and i64 matrix multiplies over 16 shapes with row
// strides wider than the rows. On arm64 macOS with FEAT_SME_I16I64 the 64-bit
// integer kernel does the work when every value fits a half (u16 / i16), and
// the loop when one does not; the hashes are the loop's either way.
// private:docs/Design/simd-sme-plan.md.
#import "Stdio.xc"
void gemmu(u64* a, u64* b, u64* c, u32 m, u32 n, u32 kk, u32 lda, u32 ldb, u32 ldc)
    {
    for (u32 i = (u32)0; i < m; i++)
        for (u32 j = (u32)0; j < n; j++)
            {
            u64 s = (u64)0;
            for (u32 k = (u32)0; k < kk; k++)
                s = s + a[i * lda + k] * b[k * ldb + j];
            c[i * ldc + j] = s;
            }
    }
void gemms(i64* a, i64* b, i64* c, u32 m, u32 n, u32 kk, u32 lda, u32 ldb, u32 ldc)
    {
    for (u32 i = (u32)0; i < m; i++)
        for (u32 j = (u32)0; j < n; j++)
            {
            i64 s = (i64)0;
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
u64 hash(u64* c, u32 n)
    {
    u64 h = (u64)1469598103934665603;
    for (u32 i = (u32)0; i < n; i++)
        h = (h ^ c[i]) * (u64)1099511628211;
    return h;
    }
i32 main(void)
    {
    u32 st = (u32)4242;
    u32 shapes[48] = {1,1,1, 1,17,3, 17,1,5, 8,8,8, 17,33,9, 31,15,64, 64,64,1, 5,7,0,
                      33,47,100, 100,37,211, 8,9,10, 65,3,129, 3,65,2, 128,128,128, 2,200,7, 40,40,40};
    for (u32 t = (u32)0; t < (u32)16; t++)
        {
        u32 m = shapes[t * (u32)3]; u32 n = shapes[t * (u32)3 + (u32)1]; u32 kk = shapes[t * (u32)3 + (u32)2];
        u32 pad = t % (u32)3;
        u32 lda = kk + pad; u32 ldb = n + pad * (u32)2; u32 ldc = n + pad;
        u32 asz = m * lda + (u32)1; u32 bsz = (kk + (u32)1) * ldb + (u32)1; u32 csz = m * ldc + (u32)1;
        u64* a = new u64[asz]; u64* b = new u64[bsz]; u64* c = new u64[csz];
        // pass 0: halves (the kernel); pass 1: one value too wide (the loop)
        for (u32 pass = (u32)0; pass < (u32)2; pass++)
            {
            for (u32 i = (u32)0; i < asz; i++) a[i] = (u64)(rng(&st) & (u32)65535);
            for (u32 i = (u32)0; i < bsz; i++) b[i] = (u64)(rng(&st) & (u32)65535);
            if (pass == (u32)1) a[asz / (u32)2] = (u64)70000;
            for (u32 i = (u32)0; i < csz; i++) c[i] = (u64)7;
            gemmu(a, b, c, m, n, kk, lda, ldb, ldc);
            Stdio.printf("u64 %u.%u %lx\n", t, pass, hash(c, csz));
            i64* sa = (i64*)a; i64* sb = (i64*)b; i64* sc = (i64*)c;
            for (u32 i = (u32)0; i < asz; i++) sa[i] = (i64)(rng(&st) & (u32)65535) - (i64)32768;
            for (u32 i = (u32)0; i < bsz; i++) sb[i] = (i64)(rng(&st) & (u32)65535) - (i64)32768;
            if (pass == (u32)1) sb[bsz / (u32)2] = (i64)-40000;
            for (u32 i = (u32)0; i < csz; i++) sc[i] = (i64)-7;
            gemms(sa, sb, sc, m, n, kk, lda, ldb, ldc);
            Stdio.printf("i64 %u.%u %lx\n", t, pass, hash(c, csz));
            }
        delete a; delete b; delete c;
        }
    return 0;
    }
