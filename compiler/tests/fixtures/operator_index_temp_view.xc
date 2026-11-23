// A get that returns a class by value which points into its owner is a
// view: setting an element through it writes into the owner. A value that
// holds no pointer is written through once it is stored in a variable; the
// write changes the variable, not the owner it was read from.
#import <Stdio.xc>

class RowView
    {
    i32* cells;
    i32 at(i32 j) :operator(self[j]) { return cells[j]; }
    void setAt(i32 j, i32 v) :operator(self[j] = v) { cells[j] = v; }
    }

class Row
    {
    i32 a;
    i32 b;
    i32 at(i32 j) :operator(self[j]) { return j == 0 ? a : b; }
    void setAt(i32 j, i32 v) :operator(self[j] = v) { if (j == 0) a = v; else b = v; }
    }

class Grid
    {
    i32 data[4];
    RowView at(i32 i) :operator(self[i]) { RowView r; r.cells = &data[i * 2]; return r; }
    Row copyOf(i32 i) { Row r; r.a = data[i * 2]; r.b = data[i * 2 + 1]; return r; }
    }

i32 main(void)
    {
    Grid* g = new Grid();
    g[1][0] = 7;
    g[1][1] += 5;
    g[0][1] = g[1][0] * 2;
    Stdio.printf("view %d %d %d %d\n", g.data[0], g.data[1], g.data[2], g.data[3]);
    Row r = g.copyOf(1);
    r[0] = 70;
    r[1] += 1;
    Stdio.printf("copy %d %d owner %d %d\n", r[0], r[1], g.data[2], g.data[3]);
    return 0;
    }
