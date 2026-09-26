//xtc-flags: expect=sema-error
// A free function with one candidate, called with no arguments.
// Refused: 'f' takes 1 argument; 0 given
#import "Stdio.xc"

void f(i32 x) { Stdio.printf("f %ld\n", x); }

void main(void)
    {
    f();
    }
