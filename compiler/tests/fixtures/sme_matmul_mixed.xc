//xtc-flags: target=arm64
// sme_matmul_mixed.xc — matrix multiplies whose two matrices differ in
// signedness (u32 × i32 into i32, i32 × u32 into u32, and the 64-bit pair).
// The product's low bits are the same under either signedness, so on arm64
// macOS the nest runs on the integer kernel of its sum's type; the hashes
// are the loop's, whichever form (bytes, halves, the loop) the values allow.
#import "Stdio.xc"
void mui(u32* a, i32* b, i32* c, u32 m, u32 n, u32 kk)
    {
    for (u32 i = (u32)0; i < m; i++)
        for (u32 j = (u32)0; j < n; j++)
            {
            i32 s = (i32)0;
            for (u32 k = (u32)0; k < kk; k++)
                s = s + a[i * kk + k] * b[k * n + j];
            c[i * n + j] = s;
            }
    }
void miu(i32* a, u32* b, u32* c, u32 m, u32 n, u32 kk)
    {
    for (u32 i = (u32)0; i < m; i++)
        for (u32 j = (u32)0; j < n; j++)
            {
            u32 s = (u32)0;
            for (u32 k = (u32)0; k < kk; k++)
                s = s + a[i * kk + k] * b[k * n + j];
            c[i * n + j] = s;
            }
    }
void mlu(i64* a, u64* b, u64* c, u32 m, u32 n, u32 kk)
    {
    for (u32 i = (u32)0; i < m; i++)
        for (u32 j = (u32)0; j < n; j++)
            {
            u64 s = (u64)0;
            for (u32 k = (u32)0; k < kk; k++)
                s = s + a[i * kk + k] * b[k * n + j];
            c[i * n + j] = s;
            }
    }
u32 rng(u32* st)
    {
    u32 x = *st;
    x = x ^ (x << (u32)13); x = x ^ (x >> (u32)17); x = x ^ (x << (u32)5);
    *st = x;
    return x;
    }
u32 hash32(u32* c, u32 n)
    {
    u32 h = (u32)2166136261;
    for (u32 i = (u32)0; i < n; i++)
        h = (h ^ c[i]) * (u32)16777619;
    return h;
    }
u64 hash64(u64* c, u32 n)
    {
    u64 h = (u64)1469598103934665603;
    for (u32 i = (u32)0; i < n; i++)
        h = (h ^ c[i]) * (u64)1099511628211;
    return h;
    }
i32 main(void)
    {
    u32 st = (u32)977;
    u32 shapes[24] = {1,1,1, 17,33,9, 31,15,64, 5,7,0, 33,47,100, 65,3,129, 128,128,128, 40,40,40};
    // value ranges: a byte, a half, wider (the loop)
    u32 masks[3] = {(u32)127, (u32)16383, (u32)$7FFFFFF};
    for (u32 t = (u32)0; t < (u32)8; t++)
        for (u32 r = (u32)0; r < (u32)3; r++)
            {
            u32 m = shapes[t * (u32)3]; u32 n = shapes[t * (u32)3 + (u32)1]; u32 kk = shapes[t * (u32)3 + (u32)2];
            u32 asz = m * kk + (u32)1; u32 bsz = kk * n + (u32)1; u32 csz = m * n + (u32)1;
            u32* ua = new u32[asz]; i32* ib = new i32[bsz]; i32* ic = new i32[csz];
            for (u32 i = (u32)0; i < asz; i++) ua[i] = rng(&st) & masks[r];
            for (u32 i = (u32)0; i < bsz; i++) ib[i] = (i32)(rng(&st) & masks[r]) - (i32)(masks[r] / (u32)2);
            mui(ua, ib, ic, m, n, kk);
            Stdio.printf("u32*i32 %u.%u %x\n", t, r, hash32((u32*)ic, csz));
            i32* ia = new i32[asz]; u32* ub = new u32[bsz]; u32* uc = new u32[csz];
            for (u32 i = (u32)0; i < asz; i++) ia[i] = (i32)(rng(&st) & masks[r]) - (i32)(masks[r] / (u32)2);
            for (u32 i = (u32)0; i < bsz; i++) ub[i] = rng(&st) & masks[r];
            miu(ia, ub, uc, m, n, kk);
            Stdio.printf("i32*u32 %u.%u %x\n", t, r, hash32(uc, csz));
            delete ia; delete ub; delete uc;
            i64* la = new i64[asz]; u64* lb = new u64[bsz]; u64* lc = new u64[csz];
            for (u32 i = (u32)0; i < asz; i++) la[i] = (i64)(rng(&st) & masks[r]) - (i64)(masks[r] / (u32)2);
            for (u32 i = (u32)0; i < bsz; i++) lb[i] = (u64)(rng(&st) & masks[r]);
            mlu(la, lb, lc, m, n, kk);
            Stdio.printf("i64*u64 %u.%u %lx\n", t, r, hash64(lc, csz));
            delete ua; delete ib; delete ic; delete la; delete lb; delete lc;
            }
    return 0;
    }
