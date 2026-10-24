// par_alias_guard_cpu — par_alias_guard with a block that has no GPU form
// (it uses double): two captured pointers that are one block of memory, one
// written, must run serially on the CPU too. The run's overlap check read the
// arrays from the kernel's header line, and a block with no form had none, so
// the check never ran and the scan ran in parallel: about 99,000 of 100,000
// values wrong on any machine with several threads (and in every static x86
// build, which has no GPU form at all). Such a block now carries the header
// alone (`// xcpar cpu`).
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
//xtc-warn: because
#import "Stdio.xc"
#import "Par.xc"

#define N 100000

i32 main(void)
{
    simd: double* a = new double[N];
    simd: double* b = a;
    for (u32 i in 0..N)
        a[i] = 1.0;
    par scan
    {
        for (u32 i in 1..N)
            b[i] = a[i - 1] + 1.0;
    }
    u32 bad = (u32)0;
    for (u32 i in 0..N)
        if (a[i] != (double)(i + (u32)1))
            bad = bad + (u32)1;
    simd: double* c = new double[N];
    par apart
    {
        for (u32 i in 1..N)
            c[i] = a[i - 1] + 1.0;
    }
    u32 bad2 = (u32)0;
    for (u32 i in 1..N)
        if (c[i] != (double)(i + (u32)1))
            bad2 = bad2 + (u32)1;
    Stdio.printf("bad=%u bad2=%u last=%f\n", bad, bad2, a[N - 1]);
    delete a;
    delete c;
    return 0;
}
