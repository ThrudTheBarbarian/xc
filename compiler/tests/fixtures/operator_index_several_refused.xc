//xtc-flags: expect=sema-error
// The built-in index takes one index.
// Refused: only a class with an index operator takes several indices, as in :operator(self[i, j])
#import <Stdio.xc>

i32 main(void)
    {
    i32* p = new i32[4];
    return p[1, 2];
    }
