//xtc-flags: -Fmb 50
// fn_min_banked.xc — `-Fmb 50` on xt6502: a function of fewer than 50
// instructions stays in main RAM, so calling it needs no bank switch; the
// larger ones still take code banks. The small helpers are called from main,
// from a banked function and from each other, and a small method is called
// through a bound callback, so every mix of placements is exercised. On the
// other targets the flag changes nothing.
#import "Stdio.xc"

i32 add3(i32 a, i32 b, i32 c)
{
    return a + b + c;
}

i32 clampTo(i32 v, i32 hi)
{
    if (v > hi)
        return hi;
    return v;
}

i32 small(i32 v)
{
    return clampTo(add3(v, 1, 2), 1000);
}

// Recursive, so the inliner leaves them as functions at every -O level, and
// small enough to stay in main RAM under -Fmb 50.
u8 depth(u8 n)
{
    if (n == 0)
        return 0;
    return depth(n - 1) + 1;
}

u16 halve(u16 v)
{
    if (v < 2)
        return v;
    return halve(v >> 1);
}

// Large enough to be banked under -Fmb 50: a long run of arithmetic and calls.
i32 large(i32 seed)
{
    i32 t = seed;
    for (i32 i = 0; i < 10; i++) {
        t = t * 3 + i;
        if (t > 5000)
            t = t - 4999;
        t = add3(t, i, small(i)) + (i32)depth((u8)i) - (i32)halve((u16)i);
        switch (i % 4) {
        case 0: t = t + 7; break;
        case 1: t = t - 3; break;
        case 2: t = t ^ 21; break;
        default: t = clampTo(t, 3000); break;
        }
    }
    u8 bytes[6];
    for (i32 k = 0; k < 6; k++)
        bytes[k] = (u8)(t + k);
    for (i32 k = 0; k < 6; k++)
        t = t + (i32)bytes[k];
    return t;
}

class Scale
{
    i32 by;

    void init(void)
    {
        by = 3;
    }

    i32 times(i32 v)
    {
        return v * by;
    }
}

i32 apply(Scale* s, i32 v)
{
    callback f i32(i32 n);
    f = &s.times;
    i32 r = large(v);
    if (f) {
        r = r + f(v);
    }
    return r;
}

i32 main(void)
{
    Stdio.printf("small(5) = %d\n", small(5));
    Stdio.printf("large(3) = %d\n", large(3));
    Scale* s = new Scale();
    Stdio.printf("times(9) = %d\n", s.times(9));
    Stdio.printf("apply(4) = %d\n", apply(s, 4));
    Stdio.printf("clampTo(2000, 1500) = %d\n", clampTo(2000, 1500));
    Stdio.printf("depth(9) = %d\n", (i32)depth(9));
    Stdio.printf("halve(40000) = %d\n", (i32)halve(40000));
    return 0;
}
