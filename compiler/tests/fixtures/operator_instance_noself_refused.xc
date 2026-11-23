//xtc-flags: expect=sema-error
// An instance method's pattern uses self.
// Refused: the :operator pattern of instance method 'neg' must use self
#import <Stdio.xc>

class V
    {
    i32 x;
    V* neg(V* o) :operator(-o) { return o; }
    }

i32 main(void) { return 0; }
