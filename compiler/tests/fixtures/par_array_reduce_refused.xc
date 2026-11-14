//xtc-flags: expect=sema-error
// An array reduction's body may only update the array, as h[k] op= x or
// h[k] = h[k] op x: a read of another element would see a chunk's private
// copy, not the array.
// Refused: ':reduce(+ hist[])': the 'par count' block uses 'hist' other than as hist[k] += x or hist[k] = hist[k] + x
//xtc-na: xt6502, m68k
#import "Stdio.xc"
#import "Par.xc"

u8 keys[1024];

i32 main(void)
    {
    u32 hist[16];
    for (u32 b in 0..16)
        hist[b] = (u32)0;
    par count :reduce(+ hist[])
        {
        for (u32 i in 0..1024)
            hist[(u32)(keys[i] & (u8)15)] = hist[(u32)(keys[i] & (u8)15)] + hist[(u32)3];
        }
    Stdio.printf("%u\n", hist[3]);
    return (i32)0;
    }
