//xtc-flags: expect=sema-error
// A class that defines `+` gives up pointer arithmetic for `+`: an unmatched `+` is an error, not a pointer step.
// Refused: 'V' has no '+' taking 'u8'
#import <Stdio.xc>

class V
    {
    i32 x;
    V* plus(V* o) :operator(self + o) { return o; }
    }

i32 main(void)
    {
    V* a = new V();
    V* b = a + 1;
    return b.x;
    }
