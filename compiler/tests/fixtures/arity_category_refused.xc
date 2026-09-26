//xtc-flags: expect=sema-error
// A method added by a category is an ordinary candidate once merged, and is
// checked like one.
// Refused: 'K.m' takes 1 argument; 0 given
#import "Stdio.xc"

class K : Object { i32 v; }

class K (Extra)
    {
    void m(i32 x) { Stdio.printf("m %ld\n", x); }
    }

void main(void)
    {
    K* k = new K();
    k.m();
    }
