//xtc-flags: expect=sema-error
// Too MANY arguments to a single-candidate static method is refused too; the
// extra value was dropped silently.
// Refused: 'K.m' takes 1 argument; 2 given
#import "Stdio.xc"

class K : Object
    {
    static void m(i32 x) { Stdio.printf("m %ld\n", x); }
    }

void main(void)
    {
    K.m(1, 2);
    }
