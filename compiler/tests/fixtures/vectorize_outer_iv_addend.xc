//xtc-flags: target=arm64
// vectorize_outer_iv_addend.xc — a vectorised INNER loop whose body adds the
// OUTER loop's induction variable. The vectoriser broadcasts the invariant
// addend with a VSplat; the outer phi carrying `rep` is CREATED by the pass
// itself when the first loop vectorises, so it is absent from the defBlk map
// computed at pass entry — and "absent" used to be read as "parameter,
// available at entry", hoisting the splat to the function entry block where
// it read a default 0. The vectorised loop then silently dropped `+ rep`
// (wasm printed sum=685440-25344 short; arm64 shared the pass and the bug).
#use Stdio

u32 src[256];
u32 dst[256];

i32 main()
{
    for (u32 i = 0; i < (u32)256; i = i + (u32)1) { src[i] = i * (u32)7; }
    for (u32 rep = 0; rep < (u32)100; rep = rep + (u32)1) {
        for (u32 i = 0; i < (u32)256; i = i + (u32)1) {
            dst[i] = src[i] * (u32)3 + rep;
        }
    }
    u32 sum = 0;
    for (u32 i = 0; i < (u32)256; i = i + (u32)1) { sum = sum + dst[i]; }
    printf("sum=%lu\n", sum);        // 21*(255*256/2) + 256*99 = 710784
    return 0;
}
