//xtc-flags: expect=sema-error
// A class with an index operator gives up the built-in index: an index no
// operator takes is an error, never pointer indexing.
// Refused: 'V' has no '[]' taking 'V*'
#import <Stdio.xc>

class V
    {
    i32 items[4];
    i32 at(i32 i) :operator(self[i]) { return items[i]; }
    }

i32 main(void)
    {
    V* v = new V();
    V* w = new V();
    V e = v[w];
    return 0;
    }
