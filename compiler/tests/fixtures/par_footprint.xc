// par_footprint.xc — the footprint each buffer gets on the kernel's header
// line (fp= / gfp=, par-tiles-and-devices.md step 1): a map (a[i]), a
// stencil (b[i - 1], b[i + 1]), a stride (c[2 * i + 1]), a table read from
// data (no footprint). The words only describe the buffers; every answer
// must be the CPU's.
//xtc-flags: target=arm64
#import "Stdio.xc"
#import "Par.xc"
#define N 4096
u32 table[N];
i32 main(i32 argc, u8** argv)
    {
    u32 a[N]; u32 b[N + 2]; u32 c[2 * N + 2]; u32 d[N];
    for (u32 i in 0..N) { a[i] = i + 1; d[i] = 0; table[i] = (i * 7) & 255; }
    for (u32 i in 0..N + 2) b[i] = i * 3;
    for (u32 i in 0..2 * N + 2) c[i] = i;
    u32 total = 0;
    par :reduce(+ total)
        {
        for (u32 i in 1..N - 1)
            {
            d[i] = a[i] * 2 + b[i - 1] + b[i + 1] + c[2 * i + 1] + table[a[i] & 255];
            total = total + d[i];
            }
        }
    u32 s = 0;
    for (u32 i in 0..N) s = s + d[i];
    Stdio.printf("%u %u\n", total, s);
    return 0;
    }
