//xtc-flags: expect=sema-error
// Two index operators that match equally well are an error naming both.
// Refused: operator '[]' on (V*, u8) is ambiguous: 'V.at' and 'V.get' both match
#import <Stdio.xc>

class V
    {
    i32 items[4];
    i32 at(i32 i) :operator(self[i]) { return items[i]; }
    i32 get(i32 i) :operator(self[i]) { return items[i] + 1; }
    }

i32 main(void)
    {
    V* v = new V();
    return v[1];
    }
