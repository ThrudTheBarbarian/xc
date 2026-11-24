//xtc-flags: expect=sema-error
// The characters of an operator are written together: `* *` is two operators.
// Refused: the characters of an operator are written together, as in (self ** o)
#import <Stdio.xc>

class V
    {
    i32 v;
    V* pow(V* o) :operator(self * * o) { return o; }
    }

i32 main(void) { return 0; }
