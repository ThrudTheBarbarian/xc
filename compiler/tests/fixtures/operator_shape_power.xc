// An operator of a class's own shape: `**` for power, made to bind more
// tightly than `*` and to group from the right with :precedence(above *,
// right). `2 * a ** b ** c` is `2 * (a ** (b ** c))`. Where `**` also reads
// the old way (`x**p` is `x * *p`), the operand types choose: on a class that
// defines `**` it is the operator, on numbers and pointers what it was.
#import <Stdio.xc>

class Num
    {
    i32 v;
    static Num* of(i32 x) { Num* n = new Num(); n.v = x; return n; }
    Num* pow(Num* e) :operator(self ** e) :precedence(above *, right)
        {
        i32 r = 1;
        for (i32 i = 0; i < e.v; i++)
            r = r * v;
        return Num.of(r);
        }
    Num* times(Num* o) :operator(self * o) { return Num.of(v * o.v); }
    static Num* scaled(i32 k, Num* n) :operator(k * n) { return Num.of(k * n.v); }
    }

i32 main(void)
    {
    Num* a = Num.of(2);
    Num* b = Num.of(3);
    Num* c = Num.of(2);
    Stdio.printf("right %d\n", (a ** b ** c).v);
    Stdio.printf("above %d\n", (2 * a ** b).v);
    Stdio.printf("both %d\n", (2 * a ** b ** c).v);
    Stdio.printf("times %d\n", (a ** c * b).v);
    Stdio.printf("joined %d\n", (a**b).v);
    i32 x = 5;
    i32* p = &x;
    i32 y = x**p;
    i32 z = 2 * x**p;
    Stdio.printf("old %d %d\n", y, z);
    return 0;
    }
