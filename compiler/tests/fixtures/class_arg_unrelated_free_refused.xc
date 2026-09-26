//xtc-flags: expect=sema-error
// A free function refuses a class unrelated to its parameter's class even when
// the argument's class has an ancestor in common with it (Object).
// Refused: argument 1 of 'f': 'B2' is not a subclass of 'A2'
#import "Stdio.xc"

class A : Object { i32 a; }
class B : Object { u8 b; }

class A2 : A { i32 c; }
class B2 : B { i32 d; }

void f(A2* x) { Stdio.printf("f %ld\n", x.c); }

void main(void)
    {
    f(new B2());
    }
