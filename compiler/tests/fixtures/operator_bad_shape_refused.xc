//xtc-flags: expect=sema-error
// A pattern is one operator applied to the method's own names.
// Refused: ':operator' takes one operator applied to the method's own names, such as (self + o) or (-self)
#import <Stdio.xc>

class V
    {
    i32 x;
    V* plus(V* o) :operator(self + o + o) { return o; }
    }

i32 main(void) { return 0; }
