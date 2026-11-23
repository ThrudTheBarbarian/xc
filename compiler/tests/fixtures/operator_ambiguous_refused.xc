//xtc-flags: expect=sema-error
// Two operator methods that fit equally well are an error naming both.
// Refused: operator '+' on (V*, V*) is ambiguous: 'V.plus' and 'V.add' both match
#import <Stdio.xc>

class V
    {
    i32 x;
    V* plus(V* o) :operator(self + o) { return o; }
    static V* add(V* a, V* b) :operator(a + b) { return a; }
    }

i32 main(void)
    {
    V* a = new V();
    V* b = new V();
    V* c = a + b;
    return c.x;
    }
