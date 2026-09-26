//xtc-flags: expect=sema-error
// A prototype and its definition are one candidate, not two.
// Refused: 'f' takes 1 argument; 0 given
#import "Stdio.xc"

void f(i32 x);

void main(void)
    {
    f();
    }

void f(i32 x) { Stdio.printf("f %ld\n", x); }
