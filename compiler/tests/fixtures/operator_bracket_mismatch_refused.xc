//xtc-flags: expect=sema-error
// A pair of brackets: ⌊ is closed by ⌋.
// Refused: '⌉' does not close '⌊': write '⌋' to close it
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
    Num* y = ⌊x⌉;
    return y.t;
    }
