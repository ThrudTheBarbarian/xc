//xtc-flags: expect=sema-error
// Grid's index get returns a Row by value, and Row holds no pointer, so
// `g[1][0] += 7` would update an element of a temporary copy: the write is lost.
// Refused: '+=' writes into a temporary copy of Row (Grid's '[]' returns Row by value), so the write is lost; store it in a variable first (Row t = ...;) and write through that, or have Grid's '[]' return a Row* or a view that points into Grid
#import <Stdio.xc>

class Row
    {
    i32 a;
    i32 b;
    i32 at(i32 j) :operator(self[j]) { return j == 0 ? a : b; }
    void setAt(i32 j, i32 v) :operator(self[j] = v) { if (j == 0) a = v; else b = v; }
    }

class Grid
    {
    i32 x0;
    i32 x1;
    Row at(i32 i) :operator(self[i]) { Row r; r.a = i == 0 ? x0 : x1; r.b = 0; return r; }
    }

i32 main(void)
    {
    Grid g;
    g[1][0] += 7;
    return 0;
    }
