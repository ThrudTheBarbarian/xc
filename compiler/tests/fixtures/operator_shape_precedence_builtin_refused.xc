//xtc-flags: expect=sema-error
// Overloading a built-in operator never changes its precedence.
// Refused: '+' keeps the precedence of the built-in operator: ':precedence' is for an operator of a class's own shape
#import <Stdio.xc>

class V
    {
    i32 v;
    V* plus(V* o) :operator(self + o) :precedence(above *) { return o; }
    }

i32 main(void) { return 0; }
