//xtc-flags: target=arm64 --par-style=auto
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_auto_gtgt.xc — a `>>` closing two type argument lists, split by the
// parser into two `>`, inside a loop --par-style=auto lifts, and after a
// running total whose :scan rewrite gives the tokens back (#499). The split
// must leave the tokens the loop is read from saying `>>`, and must not
// fail on the tokens the rewrite gave back.
#import "Stdio.xc"
#import "Par.xc"
#define N 100000
u32 a[N];
u32 b[N];
i32 main(void)
{
    for (u32 i = 0; i < N; i++) { Array<Array<String>>* z = (Array<Array<String>>*)0; b[i] = z == (Array<Array<String>>*)0 ? i : 0; }
    for (u32 i = 0; i < N; i++) a[i] = i & 7;
    u32 acc = 0;
    for (u32 i = 0; i < N; i++) { acc += a[i]; b[i] = acc; }
    Array<Array<String>>* q = (Array<Array<String>>*)0;
    Stdio.printf("%u %u %u %d\n", acc, b[5], b[N - 1], q == (Array<Array<String>>*)0 ? 1 : 0);
    return 0;
}
