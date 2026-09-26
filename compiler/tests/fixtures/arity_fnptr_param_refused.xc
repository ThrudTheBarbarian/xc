//xtc-flags: expect=sema-error
// A callback PARAMETER is checked like any function-pointer variable.
// Refused: 'cb' takes 1 argument; 2 given
#import "Stdio.xc"

typedef void cb_t(i32 x);

void f(i32 x) { Stdio.printf("f %ld\n", x); }

void run(cb_t@ cb)
    {
    cb(1, 2);
    }

void main(void)
    {
    run(&f);
    }
