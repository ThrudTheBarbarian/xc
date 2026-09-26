//xtc-flags: expect=sema-error
// A call through a protocol-typed receiver has exactly one candidate, the
// protocol's declaration, and dispatch lands in whichever class implements
// it. The count was not checked, so the body read a parameter that
// was never passed.
// Refused: 'P.m' takes 1 argument; 0 given
#import "Stdio.xc"

protocol P { void m(i32 x); }

class K <P>
    {
    void m(i32 x) { Stdio.printf("m %ld\n", x); }
    }

void call(P* p)
    {
    p.m();
    }

void main(void)
    {
    call(new K());
    }
