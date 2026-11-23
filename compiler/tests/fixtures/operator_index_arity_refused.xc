//xtc-flags: expect=sema-error
// An index operator takes as many indices as its pattern has.
// Refused: 'M' has no '[]' taking 'u8'
#import <Stdio.xc>

class M
    {
    i32 cells[4];
    i32 at(i32 r, i32 c) :operator(self[r, c]) { return cells[r * 2 + c]; }
    }

i32 main(void)
    {
    M* m = new M();
    return m[1];
    }
