//xtc-flags: expect=sema-error
// An index set is a statement, so its method returns void.
// Refused: operator method 'put' must return void: an index set or compound assignment is a statement
#import <Stdio.xc>

class V
    {
    i32 items[4];
    i32 put(i32 i, i32 x) :operator(self[i] = x) { items[i] = x; return x; }
    }

i32 main(void) { return 0; }
