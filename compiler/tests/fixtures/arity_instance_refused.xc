//xtc-flags: expect=sema-error
// An instance method with one candidate, called with too few arguments.
// Refused: 'K.m' takes 1 argument; 0 given
#import "Stdio.xc"

class K : Object
    {
    void m(i32 x) { Stdio.printf("m %ld\n", x); }
    }

void main(void)
    {
    K* k = new K();
    k.m();
    }
