// par_gcd_strides — a block that writes a[2*i] and reads a[2*i + 1]: the
// strides are equal and the offsets differ, which the first dependence rule
// took for a scan. The GCD test knows better: 2*i1 == 2*i2 + 1 has no
// integer solution, so no item reads what another writes (the even elements
// are written, the odd ones only read), and the block is a par. The result
// is exact wherever it runs: a[2i] = a[2i+1] * 3 + i.
//
//xtc-na: xt6502, m68k — par has no threads there
#import "Stdio.xc"
#import "Par.xc"

#define N 65536

u32 a[2 * N];

i32 main(void)
{
    for (u32 i in 0..2 * N)
        a[i] = i;
    par evens
    {
        for (u32 i in 0..N)
            a[2 * i] = a[2 * i + 1] * (u32)3 + i;
    }
    u32 bad = (u32)0;
    u32 sum = (u32)0;
    for (u32 i in 0..N)
    {
        if (a[2 * i] != (2 * i + (u32)1) * (u32)3 + i || a[2 * i + 1] != 2 * i + (u32)1)
            bad = bad + (u32)1;
        sum = sum + a[2 * i];
    }
    Stdio.printf("bad=%u sum=%u\n", bad, sum);
    return 0;
}
