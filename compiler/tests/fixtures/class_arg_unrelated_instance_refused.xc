//xtc-flags: expect=sema-error
// An instance method refuses an unrelated class, as a free function does.
// Refused: argument 1 of 'K.m': 'B' is not a subclass of 'A'
#import "Stdio.xc"

class A : Object { i32 a; }
class B : Object { u8 b; }

class K : Object
    {
    void m(A* x) { Stdio.printf("m %ld\n", x.a); }
    }

void main(void)
    {
    K* k = new K();
    k.m(new B());
    }
