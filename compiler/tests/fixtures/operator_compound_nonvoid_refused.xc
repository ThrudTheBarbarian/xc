//xtc-flags: expect=sema-error
// A compound assignment is a statement, so its method returns void.
// Refused: operator method 'addIn' must return void: an index set or compound assignment is a statement
#import <Stdio.xc>

class V
    {
    i32 x;
    V* addIn(V* o) :operator(self += o) { x = x + o.x; return o; }
    }

i32 main(void) { return 0; }
