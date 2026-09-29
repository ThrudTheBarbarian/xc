// An array bound written as an expression folds to its count in every
// declarator position: a struct field (named or typedef'd), a prefix array
// type and a local. Before this, a struct field or prefix type bound had to
// be a single integer literal, so `[N + 1]` was a parse error there.
#use Stdio

#define N 4

typedef struct { i32 a[N + 1]; } T;
struct S { i32 b[N * 2 - 1]; };

i32 main(void)
    {
    T t;
    S s;
    i32[2 + 3] c;
    i32 d[N << 1];
    t.a[N] = 7;
    s.b[6] = 11;
    c[4] = 9;
    d[7] = 13;
    Stdio.printf("%d %d %d %d\n", t.a[N], s.b[6], c[4], d[7]);
    Stdio.printf("%d %d %d %d\n", (i32)sizeof(T), (i32)sizeof(S), (i32)c.length, (i32)d.length);
    return 0;
    }
