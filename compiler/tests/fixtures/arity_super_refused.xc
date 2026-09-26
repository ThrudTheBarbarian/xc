//xtc-flags: expect=sema-error
// `super.m(...)` must match one of the parent's declarations. The parent's
// only candidate was taken whatever the arguments were.
// Refused: No overload of 'super.m' matches ()
#import "Stdio.xc"

class B : Object
    {
    void m(i32 x) { Stdio.printf("m %ld\n", x); }
    }

class K : B
    {
    void m(i32 x) { super.m(); }
    }

void main(void)
    {
    K* k = new K();
    k.m(1);
    }
