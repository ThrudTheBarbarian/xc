// cloaked_hello.xc — stage 4 smoke test for the :cloaked library bank.
//
// The :cloaked function writes a marker byte to a global. The
// caller brackets the JSR in PORTB = $30 / restore (codegen emits
// the bracket automatically when it sees the :cloaked annotation)
// so the library image at $4000-$7FFF is exposed during the call.
// After return, main verifies the marker changed. xe-family only;
// on xl / xt sema + codegen reject the annotation.

#import "Stdio.xc"

u8 marker;

void hello(void) : cloaked
{
    marker = $A5;
}

void main(void)
{
    marker = 0;
    hello();
    if (marker == $A5) {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL\n");
    }
    return;
}
