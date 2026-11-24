//xtc-flags: expect=sema-error
// No operator of a class's own may be spelt as a fixed built-in one: `->`
// stays member access through a pointer.
// Refused: '->' cannot be overloaded; it keeps its built-in meaning, so choose another shape
#import <Stdio.xc>

class V
    {
    i32 v;
    V* to(V* o) :operator(self -> o) { return o; }
    }

i32 main(void) { return 0; }
