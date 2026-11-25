// par_resident_lanes — a block written on a GPU and kept there (#15), then
// read by a block on the CPU's lanes, round after round: several lanes fault
// on the parked block at once. One fetches it; the others wait and their
// reads run again. Every round's sums must be the ones its GPU run wrote.
// tests/par/resident-lanes.sh widens the window (XC_PAR_RESIDENT_SLOW_MS) and
// counts the fetches: one a round.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

i32 main(void)
{
    u32 n = 1 << 20;
    u32* a = new u32[n];
    u64* part = new u64[256];
    u32 bad = 0;
    for (u32 r = 0; r < 8; r = r + 1)
    {
        u32 add = r;
        par fill
        {
            for (u32 i in 0..n)
                a[i] = i * 5 + add;
        }
        par sums
        {
            for (u32 j in 0..256)
            {
                u64 s = 0;
                for (u32 k = 0; k < 4096; k = k + 1)
                    s = s + (u64)a[j * 4096 + k];
                part[j] = s;
            }
        }
        for (u32 j = 0; j < 256; j = j + 1)
        {
            u64 want = 0;
            for (u32 k = 0; k < 4096; k = k + 1)
                want = want + (u64)((j * 4096 + k) * 5 + r);
            if (part[j] != want)
                bad = bad + 1;
        }
    }
    Stdio.printf("rounds 8, sums wrong %u, part[3] %llu\n", bad, part[3]);
    return 0;
}
