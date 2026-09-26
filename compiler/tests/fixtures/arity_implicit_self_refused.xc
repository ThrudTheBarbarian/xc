//xtc-flags: expect=sema-error
// A bare call inside a class body reaches the class's own method (the
// implicit-self call). Its single candidate is checked too.
// Refused: 'm' takes 1 argument; 2 given
#import "Stdio.xc"

class K : Object
    {
    static void m(i32 x)  { Stdio.printf("m %ld\n", x); }
    static void go(void)  { m(1, 2); }
    }

void main(void)
    {
    K.go();
    }
