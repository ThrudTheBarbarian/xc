//xtc-flags: expect=sema-error
// Every name in a pattern is self or a parameter of the method.
// Refused: 'q' in the :operator pattern of 'plus' is neither self nor one of its parameters
#import <Stdio.xc>

class V
    {
    i32 x;
    V* plus(V* o) :operator(self + q) { return o; }
    }

i32 main(void) { return 0; }
