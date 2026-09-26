//xtc-flags: expect=sema-error
// A call through a function pointer has no candidate to choose, but the
// pointer's signature fixes the count, and it was not checked.
// Refused: 'p' takes 1 argument; 0 given
#import "Stdio.xc"

typedef void cb_t(i32 x);

void f(i32 x) { Stdio.printf("f %ld\n", x); }

void main(void)
    {
    cb_t@ p = &f;
    p();
    }
