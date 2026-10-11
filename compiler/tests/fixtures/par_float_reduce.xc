// par_float_reduce.xc — a FLOAT reduction in a par block vectorises.
//
// The reduction recogniser was integer-only, so nbody's inner loop
// (`ax += mass[j]*dx/(d2*sqrt(d2))`) stayed scalar. A float reduction
// reassociates the additions, so it is taken only where the source grants it
// (a par block is :goal(speed)) and the target lowers VDiv/VSqrt and a float
// horizontal add. The sum here is exact whatever the order — every term is an
// exact half and the total is far below 2^24 — so the fixture pins that the
// vectorised path computes the same answer as the scalar one.
//
//xtc-na: xt6502, m68k — par has no threads there
#import "Stdio.xc"
#import "Par.xc"

#define N 4096

float a[N];

i32 main(void)
{
    for (u32 i in 0..N)
        a[i] = (float)(i % 8);
    float s = 0.0f;
    par t :reduce(+ s)
    {
        for (u32 i in 0..N)
            s = s + a[i] * 0.5f;
    }
    Stdio.printf("%.1f\n", (double)s);
    return 0;
}
