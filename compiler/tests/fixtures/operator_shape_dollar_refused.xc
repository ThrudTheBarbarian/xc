//xtc-flags: expect=sema-error
// `$` starts a hexadecimal literal and cannot be part of an operator.
// Refused: '$1' cannot be part of an operator, which is made of the characters + - * / % < > = ! & | ^ ~ ? : @ and the mathematical operators U+2200 to U+22FF
#import <Stdio.xc>

class V
    {
    i32 v;
    V* cash(V* o) :operator(self $1 o) { return o; }
    }

i32 main(void) { return 0; }
