//xtc-flags: expect=sema-error
// :constant names a captured array the block only reads; an array the body
// writes cannot live in a GPU's constant memory, and a name that is no
// captured array is a mistake. Both are refused at the `par`.
// Refused: ':constant(ys)': 'ys' is not an array the 'par fill' block only reads
//xtc-na: xt6502, m68k
#import "Stdio.xc"
#import "Par.xc"

i32 main(void)
{
    u32* xs = new u32[1024];
    u32* ys = new u32[1024];
    for (u32 i in 0..1024)
        xs[i] = i;
    par fill :constant(ys)
    {
        for (u32 i in 0..1024)
            ys[i] = xs[i] * (u32)3;
    }
    Stdio.printf("%u\n", ys[7]);
    return (i32)0;
}
