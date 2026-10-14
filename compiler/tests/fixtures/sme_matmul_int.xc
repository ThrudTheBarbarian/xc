//xtc-flags: target=arm64
// sme_matmul_int.xc — a dense matrix multiply over u32 and i32 elements, 18
// shapes with row strides wider than the rows, and three ranges of values:
// bytes, halves and whole words. On arm64 macOS the integer SME kernel does
// the work (idiom-matmul) when every value fits a byte (four to a word) or a
// half (two to a word, SME2); words send it back to the loop. The results must
// be the loop's, bit for bit: the 32-bit tile wraps as u32 does, so the
// hashes pin the products at every range. private:docs/Design/simd-sme-plan.md.
#import "Stdio.xc"
void gemmU(u32* a, u32* b, u32* c, u32 m, u32 n, u32 kk, u32 lda, u32 ldb, u32 ldc)
    {
    for (u32 i = (u32)0; i < m; i++)
        for (u32 j = (u32)0; j < n; j++)
            {
            u32 s = (u32)0;
            for (u32 k = (u32)0; k < kk; k++)
                s = s + a[i * lda + k] * b[k * ldb + j];
            c[i * ldc + j] = s;
            }
    }
void gemmI(i32* a, i32* b, i32* c, u32 m, u32 n, u32 kk, u32 lda, u32 ldb, u32 ldc)
    {
    for (u32 i = (u32)0; i < m; i++)
        for (u32 j = (u32)0; j < n; j++)
            {
            i32 s = (i32)0;
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
// a value of the range: 0 bytes, 1 halves, 2 words; signed ranges centred on 0
u32 pick(u32* st, u32 range, bool sgn)
    {
    u32 r = rng(st);
    if (range == (u32)0) return sgn ? (u32)(i32)(i8)(r & (u32)$FF) : r & (u32)$FF;
    if (range == (u32)1) return sgn ? (u32)(i32)(i16)(r & (u32)$FFFF) : r & (u32)$FFFF;
    return r;
    }
u32 hashOf(u32* c, u32 count)
    {
    u32 h = (u32)2166136261;
    for (u32 i = (u32)0; i < count; i++)
        h = (h ^ c[i]) * (u32)16777619;
    return h;
    }
u32 shapes[54] = {1,1,1, 1,17,3, 17,1,5, 16,16,16, 17,33,9, 31,15,64, 64,64,1, 5,7,0, 33,47,100,
                  100,37,211, 8,9,10, 65,3,129, 3,65,2, 128,128,128, 2,200,7, 40,40,40, 35,70,131, 200,3,3};
void main(void)
    {
    u32 st = (u32)12345;
    for (u32 s = (u32)0; s < (u32)18; s++)
        {
        u32 m = shapes[s * (u32)3], n = shapes[s * (u32)3 + (u32)1], kk = shapes[s * (u32)3 + (u32)2];
        u32 lda = kk + (rng(&st) % (u32)3), ldb = n + (rng(&st) % (u32)5), ldc = n + (rng(&st) % (u32)2);
        if (lda == (u32)0) lda = (u32)1;
        u32 na = m * lda + (u32)4, nb = (kk > (u32)0 ? kk : (u32)1) * ldb + (u32)4, nc = m * ldc + (u32)4;
        Stdio.printf("%2u %3ux%3ux%3u", s, m, n, kk);
        for (u32 range = (u32)0; range < (u32)3; range++)
            {
            u32* a = new u32[na];
            u32* b = new u32[nb];
            u32* c = new u32[nc];
            for (u32 i = (u32)0; i < na; i++) a[i] = pick(&st, range, false);
            for (u32 i = (u32)0; i < nb; i++) b[i] = pick(&st, range, false);
            for (u32 i = (u32)0; i < nc; i++) c[i] = (u32)$DEADBEEF;
            gemmU(a, b, c, m, n, kk, lda, ldb, ldc);
            u32 hu = hashOf(c, nc);
            for (u32 i = (u32)0; i < na; i++) a[i] = pick(&st, range, true);
            for (u32 i = (u32)0; i < nb; i++) b[i] = pick(&st, range, true);
            for (u32 i = (u32)0; i < nc; i++) c[i] = (u32)$DEADBEEF;
            gemmI((i32*)a, (i32*)b, (i32*)c, m, n, kk, lda, ldb, ldc);
            Stdio.printf(" %08x/%08x", hu, hashOf(c, nc));
            delete a;
            delete b;
            delete c;
            }
        Stdio.printf("\n");
        }
    }
