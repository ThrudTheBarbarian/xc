//xtc-flags: expect=sema-error
// `use K;` promotes K's statics into the bare-call space only where they
// FIT. A misfit is no candidate at all, so the bare name resolves to nothing.
// Refused: Call to undeclared function 'm'
#import "Stdio.xc"

class K : Object
    {
    static void m(i32 x) { Stdio.printf("m %ld\n", x); }
    }

use K;

void main(void)
    {
    m();
    }
