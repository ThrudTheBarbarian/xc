// `<=>`, a three-way comparison returning an i32. With no :precedence it
// takes the precedence of its first character, `<`: below `+`, above `==`, so
// `a + b <=> c` compares the sum and `a <=> b == 0` tests the result.
#import <Stdio.xc>

class Ver
    {
    i32 n;
    static Ver* of(i32 x) { Ver* v = new Ver(); v.n = x; return v; }
    i32 cmp(Ver* o) :operator(self <=> o) { return n < o.n ? -1 : (n > o.n ? 1 : 0); }
    Ver* add(Ver* o) :operator(self + o) { return Ver.of(n + o.n); }
    }

i32 main(void)
    {
    Ver* a = Ver.of(1);
    Ver* b = Ver.of(2);
    Ver* c = Ver.of(3);
    Stdio.printf("cmp %d %d %d\n", a <=> b, b <=> a, c <=> c);
    Stdio.printf("sum %d\n", a + b <=> c);
    Stdio.printf("eq %d\n", a <=> b == -1 ? 1 : 0);
    return 0;
    }
