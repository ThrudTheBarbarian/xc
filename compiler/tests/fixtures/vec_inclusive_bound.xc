// vec_inclusive_bound.xc — a vectorised loop whose bound is a constant reached
// with `<=`. `for (i in 0...N - 1)` is `i <= N - 1`, and once `N - 1` is
// folded to a constant the vectoriser's constant-trip path saw `i <= 199999`
// and took it as 199999 trips, as if it were `<`: the sum came out 300006
// where it is 300000. Each inclusive loop is checked against the same loop
// written with `<`, for sums, a map, a count and a byte loop, at trips that
// are and are not multiples of the vector width.
#import "Stdio.xc"

#define N 200000
u32 c[N];
u32 d[N];
u8 e[1001];

i32 main(void)
{
    for (u32 i in 0..N)
        c[i] = ((i * (u32)2654435761) ^ (u32)1) + (u32)7;

    u32 inc = (u32)0;
    for (u32 i in 0...N - 1)
        inc = inc + (c[i] & (u32)3);
    u32 exc = (u32)0;
    for (u32 i in 0..N)
        exc = exc + (c[i] & (u32)3);
    Stdio.printf("sum %u %u\n", inc, exc);

    // A literal bound, an odd trip, with `<=` written out.
    u32 odd = (u32)0;
    for (u32 i = (u32)0; i <= (u32)1002; i++)
        odd = odd + c[i];
    u32 odd2 = (u32)0;
    for (u32 i = (u32)0; i < (u32)1003; i++)
        odd2 = odd2 + c[i];
    Stdio.printf("odd %u %u\n", odd, odd2);

    // A map: every element up to and including the last is written.
    for (u32 i in 0...N - 1)
        d[i] = c[i] + (u32)1;
    u32 ds = (u32)0;
    for (u32 i in 0..N)
        ds = ds ^ (d[i] - c[i]);
    Stdio.printf("map last %u xor %u\n", d[N - 1] - c[N - 1], ds);

    // A count.
    u32 cnt = (u32)0;
    for (u32 i in 0...N - 1)
        if ((c[i] & (u32)1) != (u32)0)
            cnt++;
    u32 cnt2 = (u32)0;
    for (u32 i in 0..N)
        if ((c[i] & (u32)1) != (u32)0)
            cnt2++;
    Stdio.printf("count %u %u\n", cnt, cnt2);

    // Bytes, signed counter.
    for (i32 i = 0; i <= 1000; i++)
        e[i] = (u8)(i * 7);
    u32 es = (u32)0;
    for (i32 i = 0; i <= 1000; i++)
        es = es + (u32)e[i];
    Stdio.printf("bytes %u\n", es);
    return 0;
}
