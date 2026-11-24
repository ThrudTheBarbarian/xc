//xtc-flags: expect=sema-error
// An operator of a class's own shape has no built-in meaning: on operands
// whose classes do not define it, it is an error.
// Refused: no class defines the operator '⊗' for (i32, i32); one operand must be an instance of a class that defines it with :operator(...)
#import <Stdio.xc>

class Vec
    {
    i32 x;
    Vec* kron(Vec* o) :operator(self ⊗ o) { return o; }
    }

i32 main(void)
    {
    i32 a = 2;
    i32 b = a ⊗ a;
    return b;
    }
