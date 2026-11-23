// Operators are opt-in per class and per operator. A class with no operator
// keeps C pointer arithmetic on its pointers: `p + 3` and `q - 3` step by
// instances, `q - p` is their distance, `p < q` compares addresses. A class that defines
// `+` loses only `+`: its pointers still compare with `<` and subtract with
// `-` as addresses.
#import <Stdio.xc>

class Plain
    {
    i32 a;
    i32 b;
    }

class Adds
    {
    i32 v;
    Adds* plus(Adds* o) :operator(self + o) { Adds* r = new Adds(); r.v = v + o.v; return r; }
    }

i32 main(void)
    {
    Plain* p = new Plain();
    Plain* q = p + 3;
    Stdio.printf("plain apart %d\n", q - p > 0 ? 1 : 0);
    Stdio.printf("plain less %d %d\n", p < q ? 1 : 0, q < p ? 1 : 0);
    Plain* back = q - 3;
    Stdio.printf("plain back %d\n", back == p ? 1 : 0);

    Adds* x = new Adds();
    x.v = 7;
    Adds* y = new Adds();
    y.v = 35;
    Adds* z = x + y;
    Stdio.printf("adds %d\n", z.v);
    Stdio.printf("adds compare %d\n", x < y || y < x ? 1 : 0);
    Stdio.printf("adds same %d\n", x == x ? 1 : 0);
    Stdio.printf("adds apart %d\n", x - x == 0 ? 1 : 0);
    return 0;
    }
