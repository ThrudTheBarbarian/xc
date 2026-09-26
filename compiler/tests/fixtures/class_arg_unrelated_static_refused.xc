//xtc-flags: expect=sema-error
// A static method's class-pointer parameter refuses a class that is neither
// the declared class, a subclass nor an ancestor of it: the callee would read
// B's storage at A's field offsets.
// Refused: argument 1 of 'K.m': 'B' is not a subclass of 'A'
#import "Stdio.xc"

class A : Object { i32 a; }
class B : Object { u8 b; }

class K : Object
    {
    static void m(A* x) { Stdio.printf("m %ld\n", x.a); }
    }

void main(void)
    {
    K.m(new B());
    }
