//xtc-flags: expect=sema-error
// A protocol cannot require an operator yet.
// Refused: protocol method 'plus' cannot be an operator yet
#import <Stdio.xc>

protocol Addable
    {
    Object* plus(Object* o) :operator(self + o);
    }

i32 main(void) { return 0; }
