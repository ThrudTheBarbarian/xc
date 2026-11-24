//xtc-flags: expect=sema-error
// A bracket binds as parentheses do, so it takes no :precedence.
// Refused: ':precedence' is for an operator between two operands: the bracket operator |x| binds as parentheses do; remove ':precedence'
#import <Stdio.xc>

class Num
    {
    i32 t;
    Num* abs() :operator(|self|) :precedence(*) { return self; }
    }

i32 main(void) { return 0; }
