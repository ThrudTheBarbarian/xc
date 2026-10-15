// par_goal_directive — `#goal accuracy` sets the file's default goal: a par
// block without a :goal of its own then favours accuracy (its GPU kernel
// uses precise maths, not the fast forms), and a loop without one is an
// accuracy loop. The directive produces no output and is the same on both
// preprocessors (pp-diff); the block's placeholder tag carries the goal, so
// the lowered IR shows it (ir-diff). The body is exact integer work, so the
// result is the same on every device whatever the goal.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#goal accuracy
#import "Stdio.xc"
#import "Par.xc"

#define SIZE (64 * 1024)

i32 main(void)
{
    u32* xs = new u32[SIZE];
    u32* ys = new u32[SIZE];
    for (u32 i in 0..SIZE)
    {
        xs[i] = i * (u32)2654435761;
        ys[i] = (u32)0;
    }
    par precise
    {
        for (u32 i in 0..SIZE)
        {
            u32 v = xs[i];
            v = v ^ (v >> (u32)13);
            v = v * (u32)0x5bd1e995;
            ys[i] = v ^ (v >> (u32)15);
        }
    }
    u32 sum = (u32)0;
    for (u32 i in 0..SIZE)
        sum = sum + ys[i];
    Stdio.printf("%u\n", sum);
    return (i32)0;
}
