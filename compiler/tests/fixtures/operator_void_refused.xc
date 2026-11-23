//xtc-flags: expect=sema-error
// An operator is an expression, so its method returns one value.
// Refused: operator method 'plus' must return one value
#import <Stdio.xc>

class V
    {
    i32 x;
    void plus(V* o) :operator(self + o) { x = x + o.x; }
    }

i32 main(void) { return 0; }
