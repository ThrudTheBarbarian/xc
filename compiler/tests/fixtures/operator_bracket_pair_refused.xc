//xtc-flags: expect=sema-error
// The brackets of a pattern pair up: ⌊ is closed by ⌋.
// Refused: '⌊' is closed by '⌋', not '⌉': write (⌊self⌋)
#import <Stdio.xc>

class Num
    {
    i32 t;
    Num* floor() :operator(⌊self⌉) { return self; }
    }

i32 main(void) { return 0; }
