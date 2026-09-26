//xtc-flags: expect=sema-error
// A callback held in an ivar and called as `k.cb()`: named by its field.
// Refused: 'cb' takes 1 argument; 0 given
#import "Stdio.xc"

typedef void cb_t(i32 x);

void f(i32 x) { Stdio.printf("f %ld\n", x); }

class K : Object { cb_t@ cb; }

void main(void)
    {
    K* k = new K();
    k.cb = &f;
    k.cb();
    }
