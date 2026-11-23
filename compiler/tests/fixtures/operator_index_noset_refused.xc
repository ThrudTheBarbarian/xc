//xtc-flags: expect=sema-error
// A class with only an index get cannot assign an element through it.
// Refused: 'V' has '[]' but no '[]=' to assign an element with
#import <Stdio.xc>

class V
    {
    i32 items[4];
    i32 at(i32 i) :operator(self[i]) { return items[i]; }
    }

i32 main(void)
    {
    V* v = new V();
    v[0] = 3;
    return v[0];
    }
