// A counted loop around an inner loop that exits on data it loads runs K
// copies of its body per trip on the 64-bit targets (#41): K = 4, 3 or 2,
// whichever divides the trip. Each case's answer is the same with or
// without the copies, on every target.
#import "Stdio.xc"

u32 g[96];

void fill(u32 n, u32 seed)
    {
    for (u32 i = (u32)0; i < n; i++)
        g[i] = (i * (u32)2654435761) ^ seed;
    }

// Insertion sort from 1: trip n - 1. A value carried round the outer loop
// (moves) and read after it.
u32 sortFrom1(u32 n)
    {
    u32 moves = (u32)0;
    for (u32 i = (u32)1; i < (u32)64; i++)
        {
        u32 v = g[i]; u32 j = i;
        while (j > (u32)0 && g[j - (u32)1] > v) { g[j] = g[j - (u32)1]; j = j - (u32)1; moves = moves + (u32)1; }
        g[j] = v;
        }
    return moves;
    }

// Trip 64 (K = 4), the last j read after the loop.
u32 sortFrom0(void)
    {
    u32 last = (u32)0;
    for (u32 i = (u32)0; i < (u32)64; i++)
        {
        u32 v = g[i]; u32 j = i;
        while (j > (u32)0 && g[j - (u32)1] > v) { g[j] = g[j - (u32)1]; j = j - (u32)1; }
        g[j] = v;
        last = j;
        }
    return last;
    }

// Trip 94 (K = 2), signed index.
i32 sortSigned(void)
    {
    i32 swaps = (i32)0;
    for (i32 i = (i32)2; i < (i32)96; i++)
        {
        u32 v = g[i]; i32 j = i;
        while (j > (i32)0 && g[j - (i32)1] > v) { g[j] = g[j - (i32)1]; j = j - (i32)1; swaps = swaps + (i32)1; }
        g[j] = v;
        }
    return swaps;
    }

// Two values swapped on every trip round a search loop. Rotation leaves this
// outer loop top-tested, so it is not a candidate: the same answer.
u32 swapPair(void)
    {
    u32 a = (u32)1; u32 b = (u32)2; u32 hits = (u32)0;
    for (u32 i = (u32)1; i < (u32)64; i++)
        {
        u32 k = (u32)0;
        while (k < (u32)64 && g[k] < a * (u32)67108864) k = k + (u32)1;
        hits = hits + k;
        u32 t = a; a = b; b = t + i;
        }
    return hits * (u32)7 + a * (u32)3 + b;
    }

// A counted inner loop: not a candidate, the same answer.
u32 counted(void)
    {
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < (u32)12; i++)
        for (u32 k = (u32)0; k < (u32)8; k++)
            s = s + g[i + k];
    return s;
    }

bool sorted(u32 lo, u32 n)
    {
    for (u32 i = lo + (u32)1; i < n; i++)
        if (g[i - (u32)1] > g[i])
            return false;
    return true;
    }

i32 main(void)
    {
    fill((u32)96, (u32)12345);
    u32 m = sortFrom1((u32)64);
    Stdio.printf("from1: moves %u sorted %d first %u last %u\n", m, (i32)sorted((u32)0, (u32)64), g[0], g[63]);
    fill((u32)96, (u32)777);
    u32 l = sortFrom0();
    Stdio.printf("from0: last j %u sorted %d\n", l, (i32)sorted((u32)0, (u32)64));
    fill((u32)96, (u32)4242);
    i32 s = sortSigned();
    Stdio.printf("signed: swaps %d sorted %d\n", s, (i32)sorted((u32)0, (u32)96));
    fill((u32)96, (u32)99);
    Stdio.printf("swap pair: %u\n", swapPair());
    Stdio.printf("counted: %u\n", counted());
    return 0;
    }
