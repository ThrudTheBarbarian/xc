//xtc-flags: expect=sema-error
// A class that defines '+=' and no '+' has no built-in '+=' to fall back on.
// Refused: 'V' has no '+=' taking 'u8'
#import <Stdio.xc>

class V
    {
    i32 x;
    void addIn(V* o) :operator(self += o) { x = x + o.x; }
    }

i32 main(void)
    {
    V* v = new V();
    v += 1;
    return 0;
    }
