//xtc-flags: expect=sema-error
// An array reduction takes + | & or ^; any other operator is refused at the
// block.
// Refused: ':reduce(* prod[])': an array reduction takes + | & or ^
//xtc-na: xt6502, m68k
#import "Stdio.xc"
#import "Par.xc"

u8 keys[1024];

i32 main(void)
    {
    u32 prod[16];
    for (u32 b in 0..16)
        prod[b] = (u32)1;
    par :reduce(* prod[])
        {
        for (u32 i in 0..1024)
            prod[(u32)(keys[i] & (u8)15)] = prod[(u32)(keys[i] & (u8)15)] * (u32)3;
        }
    Stdio.printf("%u\n", prod[3]);
    return (i32)0;
    }
