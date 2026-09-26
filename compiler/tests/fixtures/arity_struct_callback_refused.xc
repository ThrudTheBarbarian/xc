//xtc-flags: expect=sema-error
// A callback held in a struct field.
// Refused: 'cb' takes 1 argument; 0 given
#import "Stdio.xc"

typedef void cb_t(i32 x);

struct S { cb_t@ cb; }

void f(i32 x) { Stdio.printf("f %ld\n", x); }

void main(void)
    {
    S s;
    s.cb = &f;
    s.cb();
    }
