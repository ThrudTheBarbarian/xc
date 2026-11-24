//xtc-flags: expect=sema-error
// :precedence belongs to an operator, on the same method.
// Refused: ':precedence' on 'pow' needs ':operator' on the same method
#import <Stdio.xc>

class V
    {
    i32 v;
    V* pow(V* o) :precedence(above *) { return o; }
    }

i32 main(void) { return 0; }
