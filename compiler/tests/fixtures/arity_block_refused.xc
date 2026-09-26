//xtc-flags: expect=sema-error
// A block call is `.invoke` dispatch, which is a method call with one
// candidate.
// Refused: 'Blk$u32$u16$u16.invoke' takes 2 arguments; 1 given
#import "Stdio.xc"
#import "Foundation.xc"

i32 main(void)
    {
    block b u32(u16 x, u16 y) = { return (u32)x + (u32)y; }
    Stdio.printf("%ld\n", b(2));
    return 0;
    }
