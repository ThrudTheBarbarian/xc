//xtc-flags: expect=sema-error
// A class that defines a prefix operator gives up its built-in meaning: one
// that no candidate fits is refused. Here `-` takes only the subclass.
// Refused: 'V' has no prefix '-' taking 'V*'
#import <Stdio.xc>

class V
    {
    i32 x;
    static V* minus(Sub* s) :operator(-s) { return s; }
    }

class Sub : V
    {
    i32 y;
    }

i32 main(void)
    {
    V* a = new V();
    V* b = -a;
    return b.x;
    }
