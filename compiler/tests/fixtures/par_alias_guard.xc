// par_alias_guard — two captured pointers that are ONE block of memory. The
// compiler's dependence check holds a buffer against itself, and here it sees
// two buffers, `a` and `b`; but `b` is `a`, so `b[i] = a[i - 1] + 1` reads
// what another item writes — a scan. The runtime notices the overlap before
// the run (ParDevice.bufferOverlap) and runs the block serially, as the
// source reads, on any device and any number of threads: a[i] = i + 1 after
// it, wherever it ran. A plain `par` over two separate blocks is unaffected.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

#define N 100000

i32 main(void)
{
    simd: u32* a = new u32[N];
    simd: u32* b = a;
    for (u32 i in 0..N)
        a[i] = (u32)1;
    par scan
    {
        for (u32 i in 1..N)
            b[i] = a[i - 1] + (u32)1;
    }
    u32 bad = (u32)0;
    for (u32 i in 0..N)
        if (a[i] != i + (u32)1)
            bad = bad + (u32)1;
    simd: u32* c = new u32[N];
    par apart
    {
        for (u32 i in 1..N)
            c[i] = a[i - 1] + (u32)1;
    }
    u32 bad2 = (u32)0;
    for (u32 i in 1..N)
        if (c[i] != i + (u32)1)
            bad2 = bad2 + (u32)1;
    Stdio.printf("bad=%u bad2=%u last=%u\n", bad, bad2, a[N - 1]);
    delete a;
    delete c;
    return 0;
}
