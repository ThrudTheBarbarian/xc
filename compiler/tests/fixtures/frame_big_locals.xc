//xtc-flags: target=arm64
// frame_big_locals.xc — the lifted arm64 frame ceiling (old 16 KB budget,
// fuzz seeds 95/165/267): a function whose locals exceed 16 KB compiles and
// runs — far-end slot accesses stage their address in x9 instead of a bare
// `[sp, #off]` whose scaled immediate cannot encode. Three big arrays force
// slots past both the w-view (16380) and x-view (32760) scaled limits, and
// the values written first are read back LAST so a mis-staged address shows.
#use Stdio

i32 main(void)
{
    u8 a[15000];
    u8 b[15000];
    u8 c[15000];
    u32 lo = (u32)7;
    a[(u32)0] = (u8)11;   a[(u32)14999] = (u8)22;
    b[(u32)0] = (u8)33;   b[(u32)14999] = (u8)44;
    c[(u32)0] = (u8)55;   c[(u32)14999] = (u8)66;
    u32 hi = (u32)9;
    printf("%d %d %d %d %d %d %lu %lu\n",
           (i16)a[(u32)0], (i16)a[(u32)14999],
           (i16)b[(u32)0], (i16)b[(u32)14999],
           (i16)c[(u32)0], (i16)c[(u32)14999], lo, hi);
    return 0;
}
