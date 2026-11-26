// A par block writing an f4 array at an index from data could have two
// work items write the two halves of one byte.
// xtc: error "a 'par' block's work items must be independent, but this one writes the f4 array 'a' at an index that is not k * i + c, so two work items could write the two halves of one byte"
#import "Stdio.xc"
#import "Par.xc"

#define N 64

f4 a[N];
u32 idx[N];

i32 main(void)
{
    for (u32 i = 0; i < N; i++)
        idx[i] = (i * 5) % N;
    par
    {
        for (u32 i in 0..N)
            a[idx[i]] = 1.5;
    }
    Stdio.printf("%f\n", a[5]);
    return 0;
}
