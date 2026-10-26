// par_inplace_rounds — a block read by one par block, which may watch it
// (write-protect it to see CPU writes), then written by the next, round after
// round, with a CPU write in between (2026-10-26). On a GPU that shares memory
// in place (an integrated GPU under Vulkan, Metal) a write-protected block
// would lose the GPU's writes; the runtime unwatches every block a run writes
// before the run, and here every round's writes must all be there.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

i32 main(void)
{
    u32 n = 1 << 20;
    u32* a = new u32[n];
    u64* part = new u64[1024];
    u32 bad = 0;
    for (u32 i = 0; i < n; i = i + 1)
        a[i] = i;
    for (u32 r = 0; r < 50; r = r + 1)
    {
        par readA
        {
            for (u32 j in 0..1024)
            {
                u64 s = 0;
                for (u32 k = 0; k < 1024; k = k + 1)
                    s = s + (u64)a[j * 1024 + k];
                part[j] = s;
            }
        }
        a[r] = 7;                       // a CPU write between the two runs
        u32 add = r;
        par writeA
        {
            for (u32 i in 0..n)
                a[i] = i * 3 + add;
        }
        for (u32 i = 0; i < n; i = i + 1)
            if (a[i] != i * 3 + r)
                bad = bad + 1;
    }
    Stdio.printf("bad %u part %llu\n", bad, part[5]);
    return 0;
}
