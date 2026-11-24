//xtc-flags: expect=sema-error
// `#` belongs to the preprocessor and cannot be part of an operator.
// Refused: '#' cannot be part of an operator, which is made of the characters + - * / % < > = ! & | ^ ~ ? : @ and the mathematical operators U+2200 to U+22FF
#import <Stdio.xc>

class V
    {
    i32 v;
    V* hash(V* o) :operator(self # o) { return o; }
    }

i32 main(void) { return 0; }
