//xtc-flags: expect=sema-error
// A single free-function candidate that does not FIT is still taken, so its
// class-pointer arguments are checked: a `B*` where an `A*` is declared would
// have the callee read B's fields at A's offsets.
// Refused: argument 1 of 'f': 'B' is not a subclass of 'A'
#import "Stdio.xc"

class A : Object { i32 a; }
class B : Object { u8 b; }

void f(A* a) { Stdio.printf("f %ld\n", a.a); }

void main(void)
    {
    f(new B());
    }
