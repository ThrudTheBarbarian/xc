// par_tiles.xc — a block big enough for the GPU runtime to cut into tiles
// (par-tiles-and-devices.md step 2): a map, a stencil, a stride and a
// reduction over a million items, with the outputs summed on the host so a
// slice copied to the wrong place, or not copied back, shows. Every answer
// must be the CPU's.
//xtc-flags: target=arm64
#import "Stdio.xc"
#import "Par.xc"
#define N (1024 * 1024)
u32 src[N + 2];
u32 dst[N];
u32 wide[2 * N + 2];
u32 out2[2 * N + 2];
i32 main(i32 argc, u8** argv)
    {
    for (u32 i in 0..N + 2) src[i] = (i * 2654435761) >> 8;
    for (u32 i in 0..2 * N + 2) wide[i] = i * 3;
    for (u32 i in 0..N) dst[i] = 0;
    for (u32 i in 0..2 * N + 2) out2[i] = 7;
    u32 total = 0;
    par :reduce(+ total)
        {
        for (u32 i in 1..N - 1)
            {
            u32 v = src[i - 1] + src[i] * 2 + src[i + 1] + wide[2 * i + 1];
            dst[i] = v;
            out2[2 * i] = v & 255;
            total = total + (v & 1023);
            }
        }
    u32 s = 0;
    u32 w = 0;
    for (u32 i in 0..N) s = s + dst[i];
    for (u32 i in 0..2 * N + 2) w = w + out2[i];
    Stdio.printf("%u %u %u\n", total, s, w);
    return 0;
    }
