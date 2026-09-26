//xtc-flags: expect=sema-error
// A call through a protocol refuses an unrelated class for a class-pointer
// parameter, as a free function does.
// Refused: argument 1 of 'Taker.take': 'B' is not a subclass of 'A'
#import "Stdio.xc"

class A : Object { i32 a; }
class B : Object { u8 b; }

protocol Taker { void take(A* x); }

class K : Object <Taker>
    {
    void take(A* x) { Stdio.printf("take %ld\n", x.a); }
    }

void main(void)
    {
    Taker@ t = new K();
    t.take(new B());
    }
