//xtc-flags: expect=sema-error
// An operator is a method of one of its operands' classes, never a free function.
// Refused: 'add' is not a method: an operator is defined by a method of one of its operands' classes
#import <Stdio.xc>

class V
    {
    i32 x;
    }

V* add(V* a, V* b) :operator(a + b) { return a; }

i32 main(void) { return 0; }
