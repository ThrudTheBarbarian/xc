//xtc-flags: expect=sema-error
// A bracket operator has no built-in meaning: on an operand whose class does not define it, it is an error.
// Refused: no class defines |x| for 'i32'; the operand must be an instance of a class that defines it with :operator(|self|)
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
    i32 a = -5;
    Num* b = |a|;
    return b.t;
    }
