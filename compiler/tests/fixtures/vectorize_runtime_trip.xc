// vectorize_runtime_trip.xc — reductions whose trip count is a RUNTIME value.
//
// `for (i = 0; i < n; i++)` is the shape essentially all real code uses, and the
// only shape a library function *can* use. Until now every recogniser required
// `resolveConstInt` on the guard's bound, so none of them vectorised — which is
// what the 3.1x/8.6x measurement against clang and gcc was actually measuring.
//
// The vector loop runs to M = n & ~(vw-1), computed in the preheader (exact:
// vw is a power of two), and a cloned scalar loop runs [M, n). No `n < vw`
// guard is needed — that case gives M = 0, the vector loop's guard fails at
// once, and the clone runs the whole range from 0.
//
// The boundary values are the point: 0 (empty), 1..3 (below one vector, so M=0
// and the vector loop never runs), 4 (exactly one vector, empty remainder), and
// 5..7 (one vector plus a tail). Sums are n(n-1)/2 over ga[i] = i.
#import "Stdio.xc"

u32 ga[64];
u32 gb[64];

u32 rsum(u32 n)
{
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1) s = s + ga[i];
    return s;
}

// A non-zero seed exercises the other epilogue path: the remainder's accumulator
// starts from the vector total, which itself started from the seed.
u32 rsumFrom(u32 n, u32 seed)
{
    u32 s = seed;
    for (u32 i = (u32)0; i < n; i = i + (u32)1) s = s + ga[i];
    return s;
}

// A MAP with a runtime bound: b[i] = f(a[i]) for i < n. Distinct from the
// reductions above because it WRITES — an epilogue that runs one iteration too
// far corrupts the element past n, which no sum over [0, n) can see. Every
// element past the bound is left at its 777 sentinel and included in the check.
u32 mapTo(u32 n)
{
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) gb[i] = (u32)777;
    for (u32 i = (u32)0; i < n; i = i + (u32)1) gb[i] = ga[i] * (u32)2 + (u32)1;
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) s = s + gb[i];
    return s;
}

void main(void)
{
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) ga[i] = i;

    // 0,1,3 are below one vector; 4 is exactly one; 5,7,63 have tails.
    Stdio.printf("%ld %ld %ld %ld %ld %ld %ld %ld\n",
        rsum((u32)0), rsum((u32)1), rsum((u32)3), rsum((u32)4),
        rsum((u32)5), rsum((u32)7), rsum((u32)63), rsum((u32)64));

    Stdio.printf("%ld %ld %ld\n",
        rsumFrom((u32)0, (u32)100), rsumFrom((u32)5, (u32)100), rsumFrom((u32)63, (u32)100));

    Stdio.printf("%ld %ld %ld %ld %ld %ld\n",
        mapTo((u32)0), mapTo((u32)1), mapTo((u32)4),
        mapTo((u32)5), mapTo((u32)7), mapTo((u32)63));
}
