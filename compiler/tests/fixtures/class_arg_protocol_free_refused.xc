//xtc-flags: expect=sema-error
// A protocol parameter of a free function refuses a class that cannot conform:
// neither it nor any subclass of it does.
// Refused: argument 1 of 'f': 'B' does not conform to protocol 'Named'
#import "Stdio.xc"

class A : Object { i32 a; }
class B : Object { u8 b; }

protocol Named { i32 id(); }

class C : A <Named> { i32 id() { return a; } }

void f(Named@ n) { Stdio.printf("f %ld\n", n.id()); }

void main(void)
    {
    f(new B());
    }
