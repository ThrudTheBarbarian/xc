//xtc-flags: expect=sema-error
// A protocol parameter of a method refuses a class that cannot conform: neither
// it nor any subclass of it does.
// Refused: argument 1 of 'K.m': 'B' does not conform to protocol 'Named'
#import "Stdio.xc"

class A : Object { i32 a; }
class B : Object { u8 b; }

protocol Named { i32 id(); }

class C : A <Named> { i32 id() { return a; } }

class K : Object
    {
    static void m(Named@ n) { Stdio.printf("m %ld\n", n.id()); }
    }

void main(void)
    {
    K.m(new B());
    }
