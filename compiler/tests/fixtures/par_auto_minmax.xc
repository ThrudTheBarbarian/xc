// par_auto_minmax — with --par-auto, a loop that keeps the smallest or the
// largest value seen, `if (x < least) least = x;`, becomes a par block with a min
// (or max) reduction; each shape of the test, with the accumulator on either
// side, gives the serial loop's answer. Under plain compilation the loops
// run as written; the answer is the same either way.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
#import "Stdio.xc"
#import "Par.xc"

#define N (1024 * 1024)

i32 main(void)
{
    u32* v = new u32[N];
    for (u32 i in 0..N)
        v[i] = (i * (u32)2654435761) >> 4;
    u32 least = (u32)$FFFFFFFF;
    u32 most = (u32)0;
    u32 least2 = (u32)$FFFFFFFF;
    u32 most2 = (u32)0;
    for (u32 i in 0..N)
        if (v[i] < least)
            least = v[i];
    for (u32 i in 0..N)
        if (v[i] > most)
            most = v[i];
    for (u32 i in 0..N)
        if (least2 > v[i])
            least2 = v[i];
    for (u32 i in 0..N)
        if (most2 <= v[i])
            most2 = v[i];
    // The check, serially.
    u32 elo = (u32)$FFFFFFFF;
    u32 ehi = (u32)0;
    for (u32 i = (u32)0; i < N; i = i + (u32)1)
    {
        u32 x = v[i];
        elo = x < elo ? x : elo;
        ehi = x > ehi ? x : ehi;
    }
    Stdio.printf("min ok=%d max ok=%d min2 ok=%d max2 ok=%d\n", (i32)(least == elo), (i32)(most == ehi),
                 (i32)(least2 == elo), (i32)(most2 == ehi));
    delete v;
    return 0;
}
