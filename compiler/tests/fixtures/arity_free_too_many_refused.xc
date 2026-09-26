//xtc-flags: expect=sema-error
// A free function with one candidate, called with an extra argument.
// Refused: 'f' takes 1 argument; 2 given
#import "Stdio.xc"

void f(i32 x) { Stdio.printf("f %ld\n", x); }

void main(void)
    {
    f(1, 2);
    }
