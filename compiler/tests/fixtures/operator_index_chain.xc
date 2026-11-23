// Chained indexing. `g[i][j] = v` reads `g[i]` with the get and assigns
// `[j] = v` with the set on what it returned; `g[i][j]` reads with get, then
// get. A get may return a built-in pointer, whose index is the built-in one,
// and a built-in array may hold objects with index operators.
//
// The rows are objects on the heap; each get hands back a temporary that the
// end of the full expression releases, so `live` returns to the count of
// rows the grids own.
#import <Stdio.xc>

i32 live;

class Row
    {
    i32 cells[4];
    void init(void) { live = live + 1; }
    void dealloc(void) { live = live - 1; }
    i32 at(i32 j) :operator(self[j]) { return cells[j]; }
    void put(i32 j, i32 x) :operator(self[j] = x) { cells[j] = x; }
    }

class Grid
    {
    Row* rows[3];
    void init(void)
        {
        for (i32 i = 0; i < 3; i = i + 1)
            rows[i] = new Row();
        }
    Row* row(i32 i) :operator(self[i]) { return rows[i]; }
    }

// A get returning a built-in pointer: `t[i][j]` indexes it the built-in way.
class Table
    {
    i32 data[12];
    i32* line(i32 i) :operator(self[i]) { return &data[i * 4]; }
    }

i32 main(void)
    {
    Grid* g = new Grid();
    for (i32 i = 0; i < 3; i = i + 1)
        for (i32 j = 0; j < 4; j = j + 1)
            g[i][j] = i * 10 + j;
    Stdio.printf("g %d %d %d\n", g[0][1], g[1][2], g[2][3]);
    g[1][1] += 100;
    g[2][0] -= 5;
    Stdio.printf("g %d %d\n", g[1][1], g[2][0]);
    Stdio.printf("live %d\n", live);

    Table* t = new Table();
    t[1][2] = 42;
    t[2][3] = t[1][2] + 1;
    t[2][3] += 10;
    Stdio.printf("t %d %d\n", t[1][2], t[2][3]);

    Row* loose[2];
    loose[0] = new Row();
    loose[1] = new Row();
    loose[1][3] = 9;
    loose[1][3] *= 7;
    Stdio.printf("loose %d live %d\n", loose[1][3], live);
    loose[0] = 0;
    loose[1] = 0;
    g = 0;
    Stdio.printf("live %d\n", live);
    return 0;
    }
