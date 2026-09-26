//xtc-flags: expect=sema-error
// An implicit-self call refuses an unrelated class, as a free function does.
// Refused: argument 1 of 'm': 'B' is not a subclass of 'A'
#import "Stdio.xc"

class A : Object { i32 a; }
class B : Object { u8 b; }

class K : Object
    {
    void m(A* x) { Stdio.printf("m %ld\n", x.a); }
    void go(B* y) { m(y); }
    }

void main(void)
    {
    K* k = new K();
    k.go(new B());
    }
