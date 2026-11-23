//xtc-flags: expect=sema-error
// With the class operand on the right, only a static operator can match.
// Refused: 'V' has no '*' taking 'u8' on the left
#import <Stdio.xc>

class V
    {
    i32 x;
    V* scaled(i32 k) :operator(self * k) { return self; }
    }

i32 main(void)
    {
    V* a = new V();
    V* b = 2 * a;
    return b.x;
    }
