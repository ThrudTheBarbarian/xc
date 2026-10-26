// simd_watch_threads — many threads write a WATCHED block at once (2026-10-26,
// found by the Astronomancy stream on Windows: a CPU block writing an array a
// GPU run had watched died with 0xC0000005). Every lane's first write faults;
// the first fault through the handler's lock makes the pages writable, and the
// handler took every later one, already in flight, for a real access
// violation. Here a block is watched and a par block on the CPU lanes writes
// all of it, 200 times; the program must finish with the right sum.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

i32 _xtc_simd_watch(pointer p);

i32 main(void)
{
    u32 n = 1 << 20;                              // 4 MB: aligned, registered
    u32* a = new u32[n];
    u32 rounds = 200;
    // On the CPU's lanes, whatever the machine: the race is between threads,
    // and a GPU that shares memory in place (Metal) would write the block
    // this test write-protects by hand, which the runtime itself never does.
    Par.device("fill", "cpu");
    for (u32 r = 0; r < rounds; r = r + 1)
    {
        _xtc_simd_watch((pointer)a);
        u32 add = r;
        par fill
        {
            for (u32 i in 0..n)
                a[i] = i + add;
        }
    }
    u64 sum = 0;
    for (u32 i = 0; i < n; i = i + 1)
        sum = sum + (u64)a[i];
    Stdio.printf("%llu\n", sum);
    return 0;
}
