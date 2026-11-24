//xtc-flags: expect=sema-error
// The brackets an operator can use are a fixed set: | ‖ ⌊ ⌋ ⌈ ⌉ ⟨ ⟩.
// Refused: '⟦' cannot be an operator's bracket: write one of | ‖ ⌊ ⌋ ⌈ ⌉ ⟨ ⟩ instead
#import <Stdio.xc>

class Num
    {
    i32 t;
    Num* whole() :operator(⟦self⟧) { return self; }
    }

i32 main(void) { return 0; }
