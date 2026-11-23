//xtc-flags: expect=sema-error
// A static method has no receiver, so its pattern cannot use self.
// Refused: the :operator pattern of static method 'plus' cannot use self
#import <Stdio.xc>

class V
    {
    i32 x;
    static V* plus(V* o) :operator(self + o) { return o; }
    }

i32 main(void) { return 0; }
