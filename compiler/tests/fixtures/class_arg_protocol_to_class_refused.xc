//xtc-flags: expect=sema-error
// A protocol value passed where a class is declared is refused when neither
// that class nor any subclass of it conforms to the protocol.
// Refused: argument 1 of 'K.m': 'Named' is not a subclass of 'B'
#import "Stdio.xc"

class A : Object { i32 a; }
class B : Object { u8 b; }

protocol Named { i32 id(); }

class C : A <Named> { i32 id() { return a; } }

class K : Object
    {
    static void m(B* x) { Stdio.printf("m %ld\n", x.b); }
    }

void pass(Named@ n) { K.m(n); }

void main(void)
    {
    pass(new C());
    }
