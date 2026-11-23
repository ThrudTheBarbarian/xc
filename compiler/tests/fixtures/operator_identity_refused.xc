//xtc-flags: expect=sema-error
// `==` and `!=` compare identity on objects; value equality is `equals`.
// Refused: '==' cannot be overloaded: it compares identity (equals compares values)
#import <Stdio.xc>

class V
    {
    i32 x;
    bool same(V* o) :operator(self == o) { return x == o.x; }
    }

i32 main(void) { return 0; }
