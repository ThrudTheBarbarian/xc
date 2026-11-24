//xtc-flags: expect=sema-error
// Inside |...| the first | after an operand closes, so a || there closes two bars.
// Refused: '||' after an operand inside |...| closes two bars, and one is open here: write '| |' to close it and start an or
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
    i32 m = 3;
    i32 r = |x|| m;
    return r;
    }
