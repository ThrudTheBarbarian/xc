//xtc-flags: expect=sema-error
// A static operator has an operand of its own class, so `i32 + i32` can never be redefined and the operator is found on that class.
// Refused: static operator 'add' needs an operand of its own class 'V'
#import <Stdio.xc>

class V
    {
    i32 x;
    static i32 add(i32 a, i32 b) :operator(a + b) { return a - b; }
    }

i32 main(void) { return 0; }
