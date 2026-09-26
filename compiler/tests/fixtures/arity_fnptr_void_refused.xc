//xtc-flags: expect=sema-error
// A `(void)` signature takes nothing.
// Refused: 'p' takes 0 arguments; 1 given
#import "Stdio.xc"

typedef void cb_t(void);

void f(void) { Stdio.printf("f\n"); }

void main(void)
    {
    cb_t@ p = &f;
    p(1);
    }
