//xtc-flags: expect=sema-error
// A variadic static method with fewer than its fixed parameters.
// Refused: 'K.m' takes at least 1 argument; 0 given
#import "Stdio.xc"

class K : Object
    {
    static void m(i32 n, ...) { Stdio.printf("m %ld\n", n); }
    }

void main(void)
    {
    K.m();
    }
