//xtc-flags: expect=sema-error
// A compound operator cannot assign through a property's setter.
// Refused: '+=' through an operator cannot assign to the property 'pos'; write the assignment out
#import <Stdio.xc>

class V
    {
    i32 x;
    V* plus(V* o) :operator(self + o) { V* r = new V(); r.x = x + o.x; return r; }
    }

class Body
    {
    V* pos;
    void setPos(V* v) { pos = v; }
    }

i32 main(void)
    {
    Body* b = new Body();
    b.pos += new V();
    return 0;
    }
