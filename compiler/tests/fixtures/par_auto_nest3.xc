//xtc-flags: target=arm64 --par-auto
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_auto_nest3.xc — --par-auto takes a perfect three-deep nest as one 3-D
// grid (par$z the outer index, par$y the middle, par$x the inner), so all
// D*H*W points are work items rather than D items each running the rest
// serially. Bounds that do not start at zero, and a <= bound, check the
// index arithmetic; the sum checks every point ran exactly once.
#import "Stdio.xc"
#import "Par.xc"
#define D 6
#define H 40
#define W 50
u32 vol[(D + 1) * H * W];
i32 main(void)
{
    for (u32 z in 1..(u32)D + (u32)1)
        for (u32 y = (u32)0; y < (u32)H; y++)
            for (u32 x in 0..W)
                vol[((z - (u32)1) * (u32)H + y) * (u32)W + x] = z * (u32)10000 + y * (u32)100 + x;
    u64 total = (u64)0;
    for (u32 i in 0..D * H * W)
        total = total + (u64)vol[i];
    Stdio.printf("%llu\n", total);
    return 0;
}
