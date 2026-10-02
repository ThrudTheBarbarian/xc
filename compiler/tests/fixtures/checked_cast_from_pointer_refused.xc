//xtc-flags: expect=sema-error
// A checked cast reads its operand's class out of the object header, so the
// operand has to be an object. A raw `pointer` need not be one, and the cast
// used to compile with no check at all: `(B* ?)p` always "succeeded", even
// when p held an A, and the code it guarded read B's fields off an A.
// Refused: a checked cast needs an object, but the operand is 'pointer'
#import "Stdio.xc"

class A : Object { i32 a; }
class B : Object { i32 b; }

i32 main(void)
{
    A* x = new A();
    pointer p = (pointer)x;
    B* y = (B* ?)p;
    Stdio.printf("%d\n", y == (B*)0 ? 1 : 0);
    return 0;
}
