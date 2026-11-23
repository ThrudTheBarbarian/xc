//xtc-flags: expect=sema-error
// A class with only an index set cannot read an element through it.
// Refused: 'V' has '[]=' but no '[]' to read an element with
#import <Stdio.xc>

class V
    {
    i32 items[4];
    void put(i32 i, i32 x) :operator(self[i] = x) { items[i] = x; }
    }

i32 main(void)
    {
    V* v = new V();
    v[0] = 3;
    i32 x = v[0];
    return x;
    }
