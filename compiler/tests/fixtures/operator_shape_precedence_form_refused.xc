//xtc-flags: expect=sema-error
// :precedence takes an operator, or `above` or `below` and one, then `, right`.
// Refused: ':precedence' takes an operator, or 'above' or 'below' and an operator, then ', right' to group from the right, such as (above *, right)
#import <Stdio.xc>

class V
    {
    i32 v;
    V* pow(V* o) :operator(self ** o) :precedence(over *) { return o; }
    }

i32 main(void) { return 0; }
