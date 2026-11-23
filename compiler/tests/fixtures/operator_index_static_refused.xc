//xtc-flags: expect=sema-error
// An index operator indexes the receiver, so it is an instance method.
// Refused: the :operator pattern of 'at' must apply its operator to self, as in (self[i]) or (self += o)
#import <Stdio.xc>

class V
    {
    i32 items[4];
    static i32 at(V* v, i32 i) :operator(v[i]) { return v.items[i]; }
    }

i32 main(void) { return 0; }
