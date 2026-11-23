//xtc-flags: expect=sema-error
// Compound-assignment operators are not defined by `:operator` yet.
// Refused: ':operator' cannot define an index or compound-assignment operator yet
#import <Stdio.xc>

class V
    {
    i32 x;
    void addIn(V* o) :operator(self += o) { x = x + o.x; }
    }

i32 main(void) { return 0; }
