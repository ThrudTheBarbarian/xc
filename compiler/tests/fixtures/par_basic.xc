//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc)
// par_basic.xc — `par` blocks on the CPU: a map over an array, `+` and `max`
// reductions, a captured scalar, an inclusive range, a named and an unnamed
// block. Par.run splits the range across threads, so the results must not
// depend on the thread count (XC_PAR_THREADS) — integer reductions are exact.
// `par` is a contextual keyword: the last lines use it as a variable name.
#import "Stdio.xc"
#import "Par.xc"

i32 main(void)
    {
    u32 a[100000];
    u32 k = (u32)3;
    u32 sum = (u32)7;
    u32 best = (u32)5;
    par fill :reduce(+ sum) :reduce(max best)
        {
        for (u32 i in 0..100000)
            {
            a[i] = (i * k) % (u32)1000;
            sum = sum + a[i];
            if (a[i] > best)
                best = a[i];
            }
        }
    u32 tot = (u32)0;
    u32 low = (u32)1000;
    par :reduce(+ tot) :reduce(min low)
        {
        for (u32 j in 0...99)
            {
            tot = tot + j;
            if (a[j * (u32)7] < low)
                low = a[j * (u32)7];
            }
        }
    Stdio.printf("sum=%u best=%u a[777]=%u tot=%u low=%u\n", sum, best, a[777], tot, low);
    u32 par[2];
    par[0] = (u32)4;
    Stdio.printf("par[0]=%u\n", par[0]);
    return 0;
    }
