// A par block writing f4 arrays at a[i] and at b[i + 1] needs chunks that
// start on both parities: no split keeps each byte on one thread.
// xtc: error "a 'par' block's work items must be independent, but this one writes f4 arrays at offsets of both parities (as a[i] and a[i + 1]), so no split of its items keeps each byte on one thread"
#import "Stdio.xc"
#import "Par.xc"

#define N 64

f4 a[N];
f4 b[N + 1];

i32 main(void)
{
    par
    {
        for (u32 i in 0..N)
            {
            a[i] = 1.5;
            b[i + 1] = 2.0;
            }
    }
    Stdio.printf("%f %f\n", a[5], b[6]);
    return 0;
}
