//xtc-flags: expect=sema-error
// An INHERITED single candidate is checked the same way, and named through
// the receiver's class.
// Refused: 'K.m' takes 1 argument; 0 given
#import "Stdio.xc"

class B : Object
    {
    void m(i32 x) { Stdio.printf("m %ld\n", x); }
    }

class K : B { }

void main(void)
    {
    K* k = new K();
    k.m();
    }
