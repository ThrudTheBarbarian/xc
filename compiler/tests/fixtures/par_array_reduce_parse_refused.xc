//xtc-flags: expect=sema-error
// `:reduce(+ h[)`: an array reduction's name is followed by `[]`.
//xtc-na: xt6502, m68k
#import "Stdio.xc"
#import "Par.xc"

u8 keys[1024];

i32 main(void)
    {
    u32 hist[16];
    par :reduce(+ hist[)
        {
        for (u32 i in 0..1024)
            hist[(u32)(keys[i] & (u8)15)] = hist[(u32)(keys[i] & (u8)15)] + (u32)1;
        }
    Stdio.printf("%u\n", hist[3]);
    return (i32)0;
    }
