// A protocol can require an operator of its own shape, with its precedence:
// `**` binds tighter than `*` and groups from the right, so `a * b ** c ** d`
// is `a * (b ** (c ** d))`. A conforming class may repeat the `:precedence`
// or leave it off; a shape has one precedence in the program.
#import <Stdio.xc>

protocol Power
    {
    Power* pow(Power* e) :operator(self ** e) :precedence(above *, right);
    Power* times(Power* o) :operator(self * o);
    i32 value(void);
    }

class Int <Power>
    {
    i32 v;
    static Int* of(i32 x) { Int* n = new Int(); n.v = x; return n; }
    Power* pow(Power* e) :operator(self ** e) :precedence(above *, right)
        {
        i32 r = 1;
        for (i32 i = 0; i < e.value(); i++)
            r = r * v;
        return Int.of(r);
        }
    Power* times(Power* o) :operator(self * o) { return Int.of(v * o.value()); }
    i32 value(void) { return v; }
    }

// Counts the calls in its value: each operator adds 1000.
class Traced <Power>
    {
    i32 v;
    static Traced* of(i32 x) { Traced* n = new Traced(); n.v = x; return n; }
    Power* pow(Power* e) :operator(self ** e) { return Traced.of(v + e.value() + 1000); }
    Power* times(Power* o) :operator(self * o) { return Traced.of(v + o.value() + 1000); }
    i32 value(void) { return v; }
    }

Power* calc(Power* a, Power* b, Power* c, Power* d)
    {
    return a * b ** c ** d;
    }

i32 main(void)
    {
    Stdio.printf("int %d\n", calc(Int.of(3), Int.of(2), Int.of(3), Int.of(2)).value());
    Stdio.printf("traced %d\n", calc(Traced.of(1), Traced.of(2), Traced.of(3), Traced.of(4)).value());
    i32 x = 3;
    i32 y = 4;
    i32* p = &y;
    Stdio.printf("numbers %d\n", x**p);
    return 0;
    }
