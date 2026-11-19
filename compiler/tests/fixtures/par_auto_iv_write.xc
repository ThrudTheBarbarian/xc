//xtc-flags: target=arm64 --par-style=auto
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_auto_iv_write.xc — with --par-style=auto, a loop whose body also steps
// its own variable stays a loop (#415). As a block, every work item has its
// own copy of i, so `i++` in the body changes nothing and every element is
// set; the loop as written skips one element after each it sets. A C-style
// loop with `i++;`, a range loop with `++i;`, and a store through `c[i++]`
// each set every other element. In a perfect nest whose inner body steps the
// inner variable, the nest is a block over the rows only, not a grid. The
// loops that count them become blocks.
#import "Stdio.xc"
#import "Par.xc"
#define N 100000
u32 a[N];
u32 b[N];
u32 c[N];
#define H 300
#define W 400
u32 g[H * W];
i32 main(void)
{
    for (u32 i = 0; i < N; i++) {
        a[i] = 1;
        i++;
    }
    for (u32 i in 0..N) {
        b[i] = i;
        ++i;
    }
    for (u32 i = 0; i < N; i++)
        c[i++] = 3;
    for (u32 y in 0..H)
        for (u32 x = 0; x < W; x++) {
            g[y * W + x] = 1;
            x++;
        }
    u32 na = 0;
    u64 sb = 0;
    u32 nc = 0;
    u32 ng = 0;
    for (u32 i in 0..N)
        na += a[i];
    for (u32 i in 0..N)
        sb += b[i];
    for (u32 i in 0..N)
        nc += c[i];
    for (u32 i in 0..H * W)
        ng += g[i];
    Stdio.printf("a=%u b=%llu c=%u g=%u\n", na, sb, nc, ng);
    return 0;
}
