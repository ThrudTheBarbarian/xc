//xtc-flags: expect=sema-error
// `#goal` takes speed or accuracy and nothing else: a misspelt goal is an
// error at the directive, not a silent default.
// Refused: '#goal' takes speed or accuracy, not 'fast'
//xtc-na: xt6502, m68k
#goal fast
#import "Stdio.xc"

i32 main(void)
{
    Stdio.printf("never\n");
    return (i32)0;
}
