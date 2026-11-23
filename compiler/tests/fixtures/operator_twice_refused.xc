//xtc-flags: expect=sema-error
// Each name appears once in a pattern.
// Refused: 'self' appears twice in the :operator pattern of 'twice'
#import <Stdio.xc>

class V
    {
    i32 x;
    V* twice() :operator(self + self) { return self; }
    }

i32 main(void) { return 0; }
