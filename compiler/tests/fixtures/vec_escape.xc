// Escape-time loops (2026-10-22): a counted loop over pixels whose body runs an
// inner loop until a per-pixel test fails goes across pixels, a lane each, the
// inner loop under a lane mask; the scalar loop finishes the last part step.
// Every start from 0 to 9, a trip count that is not a whole number of steps,
// an integer escape loop, a count stored to a[i] after the escape loop
// (as mandel_deep does), and a loop the pass must refuse (it stores inside it).
#import "Stdio.xc"
u32 seen[64];
u32 mand(u32 s, u32 n)
    {
    u32 total = (u32)0;
    for (u32 i = s; i < n; i++)
        {
        float cx = (float)(i % (u32)64) * (3.0f / 64.0f) - 2.0f;
        float cy = (float)(i / (u32)64) * (3.0f / 16.0f) - 1.5f;
        float x = 0.0f;
        float y = 0.0f;
        u32 k = (u32)0;
        while (k < (u32)100 && x * x + y * y < 4.0f)
            {
            float xt = x * x - y * y + cx;
            y = 2.0f * x * y + cy;
            x = xt;
            k = k + (u32)1;
            }
        total = total + k;
        }
    return total;
    }
u32 counts[1100];
// Integer, so exact: a float escape count near the set's edge moves with
// rounding, and -O2's fused multiply-adds round differently from -O0.
u32 deep(u32 s, u32 n)
    {
    for (u32 i in 0..1100)
        counts[i] = (u32)7;
    for (u32 i = s; i < n; i++)
        {
        u32 v = i * (u32)2654435761 + (u32)1;
        u32 k = (u32)0;
        while (k < (u32)300 && (v & (u32)255) != (u32)7)
            {
            v = v * (u32)1103515245 + (u32)12345;
            k = k + (u32)1;
            }
        counts[i] = k;
        }
    u32 h = (u32)0;
    for (u32 i in 0..1100)
        h = h * (u32)31 + counts[i];
    return h;
    }
u32 collatz(u32 s, u32 n)
    {
    u32 t = (u32)0;
    for (u32 i = s; i < n; i++)
        {
        u32 v = i + (u32)1;
        u32 k = (u32)0;
        while (k < (u32)200 && v != (u32)1)
            {
            v = (v & (u32)1) != (u32)0 ? v * (u32)3 + (u32)1 : v >> (u32)1;
            k = k + (u32)1;
            }
        t = t + k;
        }
    return t;
    }
u32 stores(u32 s)
    {
    u32 t = (u32)0;
    for (u32 i = s; i < (u32)300; i++)
        {
        float x = (float)(i % (u32)17) * 0.25f;
        u32 k = (u32)0;
        while (k < (u32)40 && x < 30.0f)
            {
            x = x * 1.5f + 0.5f;
            seen[k] = k;
            k = k + (u32)1;
            }
        t = t + k;
        }
    return t;
    }
i32 main(void)
    {
    for (u32 s in 0..10)
        Stdio.printf("start %u: mand %u %u collatz %u stores %u deep %u\n", s, mand(s, (u32)1003), mand(s, (u32)17),
                     collatz(s, (u32)4099), stores(s), deep(s, (u32)1093));
    return 0;
    }
