// What the C/C++ reader takes rather than leaving to clang
// (tests/par/c-reads.sh): local arrays (`alloca [256 x double]`, of arrays
// too), a struct zeroed and copied (llvm.memset, llvm.memcpy), and calls
// through a pointer: a function pointer, and a table of them as a C++
// vtable is.
#include <stdio.h>
#include <string.h>

struct Stats { long n, sum, min, max, hist[8]; };

struct Shape;
struct ShapeOps { long (*area)(const struct Shape*); long (*edges)(const struct Shape*); };
struct Shape { const struct ShapeOps* ops; long w, h; };

static long rectArea(const struct Shape* s) { return s->w * s->h; }
static long rectEdges(const struct Shape* s) { (void)s; return 4; }
static long triArea(const struct Shape* s) { return s->w * s->h / 2; }
static long triEdges(const struct Shape* s) { (void)s; return 3; }
static const struct ShapeOps rectOps = { rectArea, rectEdges };
static const struct ShapeOps triOps = { triArea, triEdges };

static long total(struct Shape* const* v, int n) {
    long t = 0;
    for (int i = 0; i < n; i++)
        t += v[i]->ops->area(v[i]) * v[i]->ops->edges(v[i]);
    return t;
}

static long twice(long x) { return 2 * x; }
static long cube(long x) { return x * x * x; }

static long apply(long (*f)(long), int n) {
    long t = 0;
    for (int i = 0; i < n; i++)
        t += f(i);
    return t;
}

static void stats(struct Stats* s, const int* v, int n) {
    memset(s, 0, sizeof *s);
    s->min = 1L << 40;
    for (int i = 0; i < n; i++) {
        s->n++;
        s->sum += v[i];
        if (v[i] < s->min) s->min = v[i];
        if (v[i] > s->max) s->max = v[i];
        s->hist[v[i] & 7]++;
    }
}

int main(void) {
    double a[256];
    for (int i = 0; i < 256; i++)
        a[i] = i * 0.5;
    double da = 0;
    for (int i = 0; i < 256; i++)
        da += a[255 - i] * (i & 3);
    int grid[12][10];
    for (int r = 0; r < 12; r++)
        for (int c = 0; c < 10; c++)
            grid[r][c] = r * c + 1;
    long gs = 0;
    for (int r = 1; r < 11; r++)
        for (int c = 1; c < 9; c++)
            gs += grid[r][c] * 4 - grid[r - 1][c] - grid[r + 1][c] - grid[r][c - 1] - grid[r][c + 1];
    int v[300];
    for (int i = 0; i < 300; i++)
        v[i] = (i * 37) % 101;
    struct Stats s, c;
    stats(&s, v, 300);
    c = s;
    c.hist[0] += 1000;
    struct Shape r1 = { &rectOps, 3, 4 }, t1 = { &triOps, 7, 6 }, r2 = { &rectOps, 5, 6 };
    struct Shape* sh[3] = { &r1, &t1, &r2 };
    long (*fs[2])(long) = { twice, cube };
    printf("%.1f %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld\n", da, gs, s.n, s.sum, s.min, s.max, s.hist[3], c.hist[0],
           s.hist[0], total(sh, 3), apply(fs[0], 10) + apply(fs[1], 10));
    return 0;
}
