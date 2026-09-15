//xtc-flags: target=arm64
// fma_sum_of_products.xc — bug 34. `gA[k]*gA[k] + gB[k]*gB[k]` (a sum of two
// products) must not be miscompiled by FMA contraction. The arm64 FMA fusion
// ran after register allocation and fused the FAR product, whose operands'
// registers were then reused by the NEAR product — so the fmadd read clobbered
// registers and the result came out wrong (0 / 66 instead of 312). 0.5/0.25 are
// exact in binary32, so the expected value is exact.
i32 printf(u8* f, ...);
double* ga; double* gb;
pointer malloc(u64 n);
i32 main(void) {
    ga = (double*)malloc((u64)24); gb = (double*)malloc((u64)24);
    u32 i = (u32)0; while (i < (u32)3) { ga[i] = 0.5d; gb[i] = 0.25d; i = i + (u32)1; }
    u32 k = (u32)0;
    while (k < (u32)3) {
        double s = ga[k]*ga[k] + gb[k]*gb[k];
        printf("%lld\n", (i64)(s * 1000.0d));
        k = k + (u32)1;
    }
    return 0;
}
