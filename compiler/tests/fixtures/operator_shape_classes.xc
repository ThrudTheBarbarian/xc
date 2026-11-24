// One shape defined by two classes, both giving it the same precedence: each
// class's `**` is resolved by its operands' types. A subclass inherits its
// parent's operator, and a static pattern puts a number on the left.
#import <Stdio.xc>

class Int
    {
    i32 v;
    static Int* of(i32 x) { Int* n = new Int(); n.v = x; return n; }
    Int* pow(Int* e) :operator(self ** e) :precedence(above *, right)
        {
        i32 r = 1;
        for (i32 i = 0; i < e.v; i++)
            r = r * v;
        return Int.of(r);
        }
    }

class Small : Int
    {
    }

class Real
    {
    double v;
    static Real* of(double x) { Real* r = new Real(); r.v = x; return r; }
    Real* pow(i32 e) :operator(self ** e) :precedence(above *, right)
        {
        double r = 1.0d;
        for (i32 i = 0; i < e; i++)
            r = r * v;
        return Real.of(r);
        }
    static Real* lift(i32 k, Real* r) :operator(k ** r) { return Real.of((double)k * r.v); }
    }

i32 main(void)
    {
    Int* a = Int.of(3);
    Small* s = new Small();
    s.v = 2;
    Real* h = Real.of(1.5d);
    Stdio.printf("int %d\n", (a ** s).v);
    Stdio.printf("small %d\n", (s ** a).v);
    Stdio.printf("real %d\n", (i32)((h ** 2).v * 100.0d));
    Stdio.printf("static %d\n", (i32)((4 ** h).v * 10.0d));
    return 0;
    }
