//xtc-flags: expect=sema-error
// Index operators are not defined by `:operator` yet.
// Refused: ':operator' cannot define an index or compound-assignment operator yet
#import <Stdio.xc>

class V
    {
    i32 x;
    i32 at(i32 i) :operator(self[i]) { return x + i; }
    }

i32 main(void) { return 0; }
