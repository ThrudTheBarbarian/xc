// par_grid_constant — a grid block that indexes its array with the grid's
// own constant width, `g[par.y * 640 + par.x]`, as a program with a #define
// does. The independence check reads `W * par.y + par.x` as the point's flat
// index when W is the captured width; a constant width is the same index,
// and from 0.8.1 the block's placeholder carries the constant extents so the
// check knows it (par-blocks.md §4) — no par-scatter warning, and the block
// runs on the GPU where there is one. The CPU recomputes every element.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

#define W 640
#define H 480

i32 main(void)
{
    u32* g = new u32[W * H];
    par fill :grid(W, H)
    {
        g[par.y * W + par.x] = (par.y * (u32)3) ^ par.x;
    }
    u32 bad = (u32)0;
    u32 sum = (u32)0;
    for (u32 y in 0..H)
        for (u32 x in 0..W)
        {
            if (g[y * W + x] != ((y * (u32)3) ^ x))
                bad = bad + (u32)1;
            sum = sum + g[y * W + x];
        }
    Stdio.printf("bad=%u sum=%u\n", bad, sum);
    return (i32)0;
}
