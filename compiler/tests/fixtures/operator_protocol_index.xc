// A protocol can require the index operators, `self[i]` and `self[i] = v`.
// Generic code reads and writes through them, and `g[i] += v` is a get, the
// built-in `+` and a set, on whichever class the object is.
#import <Stdio.xc>

protocol Grid
    {
    i32 at(i32 i) :operator(self[i]);
    void put(i32 i, i32 v) :operator(self[i] = v);
    }

class Dense <Grid>
    {
    i32 cells[4];
    i32 at(i32 i) :operator(self[i]) { return cells[i]; }
    void put(i32 i, i32 v) :operator(self[i] = v) { cells[i] = v; }
    }

// Stores each value doubled, and halves it on the way out.
class Doubled <Grid>
    {
    i32 cells[4];
    i32 at(i32 k) :operator(self[k]) { return cells[k] / 2; }
    void put(i32 k, i32 x) :operator(self[k] = x) { cells[k] = x * 2; }
    }

void fill(Grid* g)
    {
    for (i32 i = 0; i < 4; i++)
        g[i] = 3 * i + 1;
    g[2] += 100;
    }

i32 total(Grid* g)
    {
    i32 s = 0;
    for (i32 i = 0; i < 4; i++)
        s = s + g[i];
    return s;
    }

i32 main(void)
    {
    Dense* d = new Dense();
    Doubled* h = new Doubled();
    fill(d);
    fill(h);
    Stdio.printf("dense %d %d %d %d total %d\n", d[0], d[1], d[2], d[3], total(d));
    Stdio.printf("doubled %d %d raw %d total %d\n", h[1], h[2], h.cells[2], total(h));
    return 0;
    }
