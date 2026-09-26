//xtc-flags: expect=sema-error
// A static method with ONE candidate is taken without overload scoring, and
// its argument count was not checked: `K.m()` against `m(i32)` compiled and
// the body printed whatever the argument register held.
// Refused: 'K.m' takes 1 argument; 0 given
#import "Stdio.xc"

class K : Object
    {
    static void m(i32 x) { Stdio.printf("m %ld\n", x); }
    }

void main(void)
    {
    K.m();
    }
