// Index operators on a vector. `:operator(self[i])` makes `v[i]` a call of
// `at`, and `:operator(self[i] = x)` makes `v[i] = x` a call of `put`; the
// methods keep their names. `v[i] op= x` reads with the get, applies the
// operator at the element's type and writes with the set.
//
// A class with an index operator gives up the built-in index for its
// pointers; `w[1]` on a class without one is still pointer indexing.
#import <Stdio.xc>

i32 live;

class Vector
    {
    i32 items[8];
    void init(void) { live = live + 1; }
    void dealloc(void) { live = live - 1; }
    i32 at(i32 i) :operator(self[i]) { return items[i]; }
    void put(i32 i, i32 x) :operator(self[i] = x) { items[i] = x; }
    }

class Plain
    {
    i32 x;
    }

i32 main(void)
    {
    Vector* v = new Vector();
    for (i32 i = 0; i < 8; i = i + 1)
        v[i] = i * 10;
    Stdio.printf("v %d %d %d\n", v[0], v[3], v[7]);
    v[2] = v[3] + v[4];
    Stdio.printf("set %d named %d\n", v[2], v.at(2));
    v[1] += 5;
    v[1] -= 2;
    v[1] *= 3;
    v[5] <<= 1;
    v[6] |= 3;
    Stdio.printf("compound %d %d %d\n", v[1], v[5], v[6]);
    i32 k = 4;
    v[k] = v[k - 1] * 2;
    Stdio.printf("k %d\n", v[k]);
    i32 sum = 0;
    for (i32 i = 0; i < 8; i = i + 1)
        sum = sum + v[i];
    Stdio.printf("sum %d\n", sum);
    Plain* ps = new Plain[3];
    ps[1].x = 7;
    Plain* w = ps;
    Stdio.printf("pointer %d\n", w[1].x);
    Stdio.printf("live %d\n", live);
    v = 0;
    Stdio.printf("live %d\n", live);
    return 0;
    }
