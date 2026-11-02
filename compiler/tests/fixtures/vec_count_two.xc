// vec_count_two.xc — two compare-and-count reductions in one vectorised loop:
// `if (c[i] == 1) a++; if (c[i] == 37) b++;`. Both compilers vectorise it
// alike (the port once made an extra splat of a constant the reference shares,
// 2026-11-02).
#import "Stdio.xc"

#define N 4099
u32 c[N];

i32 main(void)
    {
    for (u32 i = (u32)0; i < (u32)N; i++)
        c[i] = (i * (u32)2654435761) % (u32)41;
    u32 a = (u32)0;
    u32 b = (u32)0;
    for (u32 i = (u32)0; i < (u32)N; i++)
        {
        if (c[i] == (u32)1)
            a++;
        if (c[i] == (u32)37)
            b++;
        }
    Stdio.printf("%u %u\n", a, b);
    return 0;
    }
