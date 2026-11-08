// par_vec_chain_sum.xc — par bodies that are a serial chain per item and also
// sum across items (#21): the escape vectoriser runs several vector chains
// side by side (four on arm64, two on x86-64) for a counted inner loop, and
// with a sum each copy adds its lanes' reduction in turn. An integer chain
// summed, and a chain whose item also lands in an array, over a range that is
// no multiple of the copies' width, against the same work done serially.
#import "Stdio.xc"
#import "Par.xc"
#define N 100003
#define ROUNDS 37
i32 main(i32 argc, u8** argv)
{
    u32* a = new u32[N];
    u32* sa = new u32[N];
    for (u32 i in 0..N)
    {
        a[i] = i * (u32)2654435761;
        sa[i] = a[i];
    }
    u32 total = (u32)0;
    par mulsum :reduce(+ total)
    {
        for (u32 i in 0..N)
        {
            u32 v = a[i];
            for (u32 k in 0..ROUNDS)
                v = v * (u32)1664525 + (u32)1013904223 + i;
            a[i] = v;
            total = total + v;
        }
    }
    u32 shifted = (u32)0;
    par shiftsum :reduce(+ shifted)
    {
        for (u32 i in 0..N)
        {
            u32 v = i;
            for (u32 k in 0..ROUNDS)
                v = ((v << (u32)5) ^ (v >> (u32)3)) + (u32)1013904223 + i;
            shifted = shifted + (v & (u32)$FFFF);
        }
    }
    u32 want = (u32)0;
    u32 wantShift = (u32)0;
    u32 bad = (u32)0;
    for (u32 i in 0..N)
    {
        u32 v = sa[i];
        for (u32 k in 0..ROUNDS) v = v * (u32)1664525 + (u32)1013904223 + i;
        if (v != a[i]) bad = bad + (u32)1;
        want = want + v;
        u32 w = i;
        for (u32 k in 0..ROUNDS) w = ((w << (u32)5) ^ (w >> (u32)3)) + (u32)1013904223 + i;
        wantShift = wantShift + (w & (u32)$FFFF);
    }
    Stdio.printf("items wrong %u, sum %s, shifted sum %s\n", bad, total == want ? "right" : "WRONG",
                 shifted == wantShift ? "right" : "WRONG");
    return 0;
}
