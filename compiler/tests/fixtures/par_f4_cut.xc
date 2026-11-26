// par_f4_cut.xc — how the par runtime cuts a range for a block that writes f4
// arrays (Par.cut, Par.pairsOf). With the parity a block's header line gives,
// every cut inside the range falls where k * i + c is even, so no two chunks
// share a byte, the chunks still cover the range in order, and the first
// starts at its start. A block without the word is cut as before.
//xtc-na: xt6502, m68k — no par runtime there
#define ENABLE_64BIT 1
#import "Stdio.xc"
#import "Par.xc"

// Globals, so the loops below stay loops and no GPU sees them.
u32 gBad;
u32 gRuns;

u32 cuts(i64 lo, i64 n, i64 k, i32 pair)
{
    u32 bad = 0;
    i64 prev = lo;
    if (Par.cut(lo, n, 0, k, pair) != lo || Par.cut(lo, n, k, k, pair) != lo + n)
        bad++;
    for (i64 j = 1; j < k; j++)
        {
        i64 b = Par.cut(lo, n, j, k, pair);
        if (b < prev || b > lo + n)
            bad++;
        if (pair >= 0 && b < lo + n && ((b ^ (i64)pair) & 1) != 0)
            bad++;
        if (pair < 0 && b != lo + (n * j) / k)
            bad++;
        prev = b;
        }
    return bad;
}

i32 main(void)
{
    for (i64 n = 1; n < 48; n++)
        for (i64 k = 1; k < 18; k++)
            for (i32 p = -1; p < 2; p++)
                {
                gBad = gBad + cuts(0, n, k, p) + cuts(5, n, k, p);
                gRuns = gRuns + 2;
                }
    gBad = gBad + cuts(0, 1001, 3, 0) + cuts(0, 1001, 7, 0) + cuts(0, 1001, 16, 1);
    Stdio.printf("cuts %d bad %d\n", (i16)gRuns, (i16)gBad);
    Stdio.printf("%d %d %d %d\n", (i16)Par.pairsOf("// xcpar cpu\n"), (i16)Par.pairsOf("// xcpar cpu buf=32:1:1 pairs=0\n"),
                 (i16)Par.pairsOf("// xcpar cpu pairs=1\n"), (i16)Par.pairsOf("// xcpar cpu\n pairs=1"));
    return 0;
}
