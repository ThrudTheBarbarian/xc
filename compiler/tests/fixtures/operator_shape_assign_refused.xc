//xtc-flags: expect=sema-error
// A shape that starts with an assignment and goes on with prefix operators
// already reads as the assignment between two operands: `a =- b` is `a = -b`.
// Refused: '=-' cannot be an operator: between two operands it already reads as '=' followed by a prefix operator
#import <Stdio.xc>

class V
    {
    i32 v;
    V* minus(V* o) :operator(self =- o) { return o; }
    }

i32 main(void) { return 0; }
