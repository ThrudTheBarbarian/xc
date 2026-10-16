//xtc-flags: target=arm64 --par-auto
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc)
// par_auto_corpus.xc — the corpus's own --par-auto fixture (the sweeps pass
// the flag a fixture names in its //xtc-flags: line). An element map and an
// integer reduction become `par` blocks; a scan is wrapped and then demoted
// to a serial run; a loop writing an outer scalar is left alone. The output
// is the plain build's, whatever the thread count.
#import "Stdio.xc"
#import "Par.xc"
#define N 100000
u32 a[N];
u32 b[N];
i32 main(void)
    {
    for (u32 i in 0..N)
        a[i] = i * (u32)2654435761;
    u32 total = (u32)0;
    for (u32 i in 0..N)
        total = total + (a[i] >> (u32)3);
    b[0] = (u32)1;
    for (u32 i in 1..N)
        b[i] = b[i - 1] + (u32)3;
    u32 last = (u32)0;
    for (u32 i in 0..N)
        last = a[i] ^ last;
    Stdio.printf("total=%u b=%u last=%u a=%u\n", total, b[N - 1], last, a[777]);
    return 0;
    }
