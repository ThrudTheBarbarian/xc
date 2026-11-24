//xtc-flags: expect=sema-error
// An operator is made of symbol characters: a letter cannot be one.
// Refused: 'x' cannot be part of an operator, which is made of the characters + - * / % < > = ! & | ^ ~ ? : @ and the mathematical operators U+2200 to U+22FF
#import <Stdio.xc>

class V
    {
    i32 v;
    V* cross(V* o) :operator(self x o) { return o; }
    }

i32 main(void) { return 0; }
