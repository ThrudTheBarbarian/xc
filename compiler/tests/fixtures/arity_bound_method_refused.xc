//xtc-flags: expect=sema-error
// A call through a bound method (`^`) is checked against its signature.
// Refused: 'p' takes 1 argument; 0 given
#import "Stdio.xc"

typedef void cb_t(i32 x);

class K : Object
    {
    void m(i32 x) { Stdio.printf("m %ld\n", x); }
    }

void main(void)
    {
    K* k = new K();
    cb_t^ p = &k.m;
    p();
    }
