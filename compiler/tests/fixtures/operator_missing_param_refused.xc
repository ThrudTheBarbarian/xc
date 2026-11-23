//xtc-flags: expect=sema-error
// Every parameter of an operator method appears in its pattern.
// Refused: parameter 'k' of 'plus' does not appear in its :operator pattern
#import <Stdio.xc>

class V
    {
    i32 x;
    V* plus(V* o, i32 k) :operator(self + o) { return o; }
    }

i32 main(void) { return 0; }
