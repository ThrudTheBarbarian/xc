//xtc-flags: target=arm64 --par-style=auto
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_auto_bound_write.xc — with --par-style=auto, a loop whose bound the body
// changes stays a loop (#416). A block reads its bound once, before its items
// run; the loop as written reads it before each iteration. A sum that is also
// the bound, a bound read through a pointer the body stores through, and a
// counted while loop whose bound the body lowers, each give the loop's answer.
#import "Stdio.xc"
#import "Par.xc"
#define N 100000
u32 a[N];
u32 b[N];
i32 main(void)
{
    for (u32 i in 0..N)
        a[i] = i >= 1000 && i < 3000 ? 1 : 0;
    // The bound grows with the sum: 4000 iterations, not 2000.
    u32 total = 2000;
    for (u32 i = 0; i < total; i++)
        total += a[i];
    // The bound is lowered through a pointer partway through.
    u32* lim = new u32[1];
    lim[0] = 50000;
    for (u32 i = 0; i < *lim; i++) {
        b[i] = 1;
        if (i == 99)
            *lim = 100;
    }
    u32 nb = 0;
    for (u32 i in 0..N)
        nb += b[i];
    // A while loop whose bound drops by two each time: v ends at 34.
    u32 v = 0;
    u32 n = 100;
    while (v < n) {
        b[v] = 7;
        n -= 2;
        v++;
    }
    Stdio.printf("total=%u nb=%u v=%u n=%u\n", total, nb, v, n);
    return 0;
}
