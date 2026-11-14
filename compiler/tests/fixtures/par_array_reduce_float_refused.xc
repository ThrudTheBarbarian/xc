//xtc-flags: expect=sema-error
// An array reduction takes integer elements only: a float sum depends on the
// order the chunks are folded in.
// Refused: ':reduce(+ acc[])': 'acc' is not an array of integers (u8 to u64, i8 to i64) of a size known when the program is built
//xtc-na: xt6502, m68k
#import "Stdio.xc"
#import "Par.xc"

u8 keys[1024];

i32 main(void)
    {
    float acc[16];
    for (u32 b in 0..16)
        acc[b] = 0.0;
    par :reduce(+ acc[])
        {
        for (u32 i in 0..1024)
            acc[(u32)(keys[i] & (u8)15)] = acc[(u32)(keys[i] & (u8)15)] + 1.5;
        }
    Stdio.printf("%f\n", (double)acc[3]);
    return (i32)0;
    }
