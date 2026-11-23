//xtc-flags: expect=sema-error
// An element read through an index operator is a call's result, with no
// slot for '++' to step.
// Refused: '++' and '--' cannot step an element read through an index operator; use '+= 1' or '-= 1'
#import <Stdio.xc>

class V
    {
    i32 items[4];
    i32 at(i32 i) :operator(self[i]) { return items[i]; }
    void put(i32 i, i32 x) :operator(self[i] = x) { items[i] = x; }
    }

i32 main(void)
    {
    V* v = new V();
    v[0]++;
    return 0;
    }
