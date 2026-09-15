// A loop whose induction variable starts at a NON-ZERO value, indexing an
// array. The pointer-induction-variable pass rewrote `p[i]` into a pointer that
// advances each iteration, but seeded it with `p` instead of `p + a` — so this
// read from the START of the array however the loop was entered. Correct at
// -O0/-O1 (the pass runs at -O2+), wrong at -O2 and -O3: #1125.
//
// `copy2` is the `p[base + k]` form, which was always correct because its index
// is not a plain affine function of the loop counter — it is here so a
// regression breaking BOTH is distinguishable from one breaking the rewrite.
// `copy3` adds a stride, so the seed is exercised alongside a step.
//
// Collected into a buffer and printed with Stdio.printf rather than a
// per-character primitive, because `_putc` is not declared on every platform.
#import "Stdio.xc"

void copy1(u8* d, u8* p, u32 a, u32 b)
{
    u32 n = (u32)0;
    for (u32 i = a; i < b; i++) { d[n] = p[i]; n = n + (u32)1; }
    d[n] = (u8)0;
}

void copy2(u8* d, u8* p, u32 a, u32 b)
{
    u32 n = b - a;
    for (u32 k = (u32)0; k < n; k++) { d[k] = p[a + k]; }
    d[n] = (u8)0;
}

void copy3(u8* d, u8* p, u32 a, u32 b)
{
    u32 n = (u32)0;
    for (u32 i = a; i < b; i = i + (u32)2) { d[n] = p[i]; n = n + (u32)1; }
    d[n] = (u8)0;
}

i32 main(void)
{
    u8 s[8];
    u8 out[8];
    s[0]=(u8)$41; s[1]=(u8)$42; s[2]=(u8)$43; s[3]=(u8)$44;
    s[4]=(u8)$45; s[5]=(u8)$46; s[6]=(u8)$47; s[7]=(u8)0;
    copy1(&out[0], &s[0], (u32)2, (u32)5); Stdio.printf("%s\n", &out[0]);   // CDE
    copy2(&out[0], &s[0], (u32)2, (u32)5); Stdio.printf("%s\n", &out[0]);   // CDE
    copy3(&out[0], &s[0], (u32)1, (u32)7); Stdio.printf("%s\n", &out[0]);   // BDF
    return 0;
}
