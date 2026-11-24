//xtc-flags: expect=sema-error
// A bracket that is never closed.
// Refused: '⌊' at line 17, column 14 is not closed: add '⌋' after its operand, here
#import <Stdio.xc>

class Num
    {
    i32 t;
    static Num* of(i32 v) { Num* n = new Num(); n.t = v; return n; }
    Num* floor() :operator(⌊self⌋) { return self; }
    Num* abs() :operator(|self|) { return self; }
    }

i32 main(void)
    {
    Num* x = Num.of(5);
    Num* y = ⌊x;
    return y.t;
    }
