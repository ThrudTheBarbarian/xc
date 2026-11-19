//xtc-flags: target=arm64 --par-style=auto
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_auto_while_field.xc — with --par-style=auto, a counted while loop whose
// counter is not a local variable stays a loop (#463). The while form becomes
// a for loop over a fresh variable, with the counter set to the bound after
// it; neither holds for a field or a global. A field counter and a global
// counter each keep the value the loop leaves them.
#import "Stdio.xc"
#import "Par.xc"
#define N 300000
u32 g[N];
u32 h[N];
u32 gn;
class Vec
    {
    u32 _n;
    void put(u32 i)
        {
        while (_n <= i) { g[_n] = _n + 1; _n = _n + 1; }
        }
    u32 n(void) { return _n; }
    }
void fill(u32 lim)
{
    while (gn < lim) { h[gn] = gn * 2; gn++; }
}
i32 main(void)
{
    Vec* v = new Vec();
    v.put(N - 2);
    u64 s = 0;
    for (u32 k = 0; k < N; k = k + 1)
        s = s + g[k];
    fill(N - 5);
    u64 t = 0;
    for (u32 k = 0; k < N; k = k + 1)
        t = t + h[k];
    Stdio.printf("n=%u sum=%llu gn=%u sum2=%llu\n", v.n(), s, gn, t);
    return 0;
}
