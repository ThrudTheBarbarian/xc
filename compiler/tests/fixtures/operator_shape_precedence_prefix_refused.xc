//xtc-flags: expect=sema-error
// A prefix operator binds as the built-in prefix operators do.
// Refused: ':precedence' is for an operator between two operands: the prefix '√' binds as the built-in prefix operators do; remove ':precedence'
#import <Stdio.xc>

class V
    {
    i32 v;
    V* root() :operator(√self) :precedence(*) { return self; }
    }

i32 main(void) { return 0; }
