// Vector register pressure (2026-10-22): a loop body with 32 constants, each
// splat live through the loop, needs more vector registers than there are.
// The allocator gives up constant splats and makes each again where it is
// read; it used to stop the build ("vector register pressure exceeded").
#import "Stdio.xc"
#define N 4096
u32 xs[N];
u32 run(u32 seed)
    {
    for (u32 i in 0..N)
        xs[i] = i * (u32)2654435761 + seed;
    u32 total = (u32)0;
    for (u32 i in 0..N)
        {
        u32 x = xs[i];
        total = total + ((x * (u32)653163) ^ (u32)274281999) + ((x * (u32)777823) ^ (u32)384974576) + ((x * (u32)833823) ^ (u32)741361656) + ((x * (u32)988233) ^ (u32)903565517) + ((x * (u32)775843) ^ (u32)700113704) + ((x * (u32)967131) ^ (u32)569125962) + ((x * (u32)30417) ^ (u32)902316928) + ((x * (u32)488243) ^ (u32)833179166) + ((x * (u32)989185) ^ (u32)267418254) + ((x * (u32)680503) ^ (u32)55677007) + ((x * (u32)944665) ^ (u32)168417828) + ((x * (u32)118709) ^ (u32)399210080) + ((x * (u32)491857) ^ (u32)932486209) + ((x * (u32)258553) ^ (u32)408835700) + ((x * (u32)570177) ^ (u32)109494178) + ((x * (u32)601823) ^ (u32)267716823);
        }
    return total;
    }
i32 main(void)
    {
    Stdio.printf("%u %u\n", run((u32)1), run((u32)7));
    return 0;
    }
