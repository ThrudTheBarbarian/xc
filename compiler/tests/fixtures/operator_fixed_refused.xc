//xtc-flags: expect=sema-error
// `&&` keeps its short-circuit meaning and cannot be overloaded.
// Refused: '&&' cannot be overloaded; it keeps its built-in meaning, so choose another shape
#import <Stdio.xc>

class V
    {
    i32 x;
    bool both(V* o) :operator(self && o) { return true; }
    }

i32 main(void) { return 0; }
