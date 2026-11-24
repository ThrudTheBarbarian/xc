//xtc-flags: expect=sema-error
// A bracket operator has one operand.
// Refused: a bracket operator takes one operand: write (|self|), or (|x|) on a static method with one parameter
#import <Stdio.xc>

class Num
    {
    i32 t;
    Num* dist(Num* o) :operator(|self o|) { return o; }
    }

i32 main(void) { return 0; }
