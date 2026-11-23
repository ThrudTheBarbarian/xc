//xtc-flags: expect=sema-error
// An operator method takes exactly the operands its pattern names.
// Refused: operator method 'plus' cannot take '...'
#import <Stdio.xc>

class V
    {
    i32 x;
    V* plus(V* o, ...) :operator(self + o) { return o; }
    }

i32 main(void) { return 0; }
