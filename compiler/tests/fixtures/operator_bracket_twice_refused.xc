//xtc-flags: expect=sema-error
// A class has one meaning for each bracket: |M| is the determinant or the norm.
// Refused: 'Mat.norm' gives |x| a second meaning: 'Mat.det' defines it already; remove ':operator' from one of them and call it by name
#import <Stdio.xc>

class Mat
    {
    i32 a;
    i32 det() :operator(|self|) { return a; }
    i32 norm() :operator(|self|) { return a; }
    }

i32 main(void) { return 0; }
