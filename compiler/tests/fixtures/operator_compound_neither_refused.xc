//xtc-flags: expect=sema-error
// A class that defines operators, but neither '+=' nor '+', gets no
// built-in '+=' of two pointers.
// Refused: 'V' has no '+=' or '+' taking 'V*'
#import <Stdio.xc>

class V
    {
    i32 x;
    V* times(V* o) :operator(self * o) { return o; }
    void timesIn(V* o) :operator(self *= o) { x = x * o.x; }
    }

i32 main(void)
    {
    V* a = new V();
    V* b = new V();
    a += b;
    return 0;
    }
