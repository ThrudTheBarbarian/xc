// An index operator taking several indices: `:operator(self[r, c])` makes
// `m[r, c]` a call of `at`, and `:operator(self[r, c] = x)` makes
// `m[r, c] = x` a call of `put`. `m[r, c] += x` is get, op, set.
#import <Stdio.xc>

class Matrix
    {
    float cells[9];
    float at(i32 r, i32 c) :operator(self[r, c]) { return cells[r * 3 + c]; }
    void put(i32 r, i32 c, float x) :operator(self[r, c] = x) { cells[r * 3 + c] = x; }
    static Matrix* identity(void)
        {
        Matrix* m = new Matrix();
        for (i32 i = 0; i < 3; i = i + 1)
            m[i, i] = 1.0;
        return m;
        }
    Matrix* times(Matrix* o) :operator(self * o)
        {
        Matrix* p = new Matrix();
        for (i32 r = 0; r < 3; r = r + 1)
            for (i32 c = 0; c < 3; c = c + 1)
                {
                float s = 0.0;
                for (i32 k = 0; k < 3; k = k + 1)
                    s = s + self[r, k] * o[k, c];
                p[r, c] = s;
                }
        return p;
        }
    }

void show(string label, Matrix* m)
    {
    Stdio.printf("%s", label);
    for (i32 r = 0; r < 3; r = r + 1)
        for (i32 c = 0; c < 3; c = c + 1)
            Stdio.printf(" %d", (i32)(m[r, c] * 10.0));
    Stdio.printf("\n");
    }

i32 main(void)
    {
    Matrix* m = Matrix.identity();
    m[0, 2] = 2.5;
    m[2, 0] = 0.5;
    m[1, 1] += 1.5;
    m[2, 2] *= 4.0;
    show("m", m);
    Matrix* sq = m * m;
    show("sq", sq);
    show("i", Matrix.identity() * m);
    return 0;
    }
