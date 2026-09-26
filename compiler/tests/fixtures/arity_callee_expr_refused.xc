//xtc-flags: expect=sema-error
// A callee that is an expression — here the result of another call — is
// checked against the type it yields.
// Refused: '<function pointer>' takes 1 argument; 0 given
#import "Stdio.xc"

typedef void cb_t(i32 x);

void f(i32 x) { Stdio.printf("f %ld\n", x); }

cb_t@ get(void) { return &f; }

void main(void)
    {
    get()();
    }
