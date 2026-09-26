// overload_return_type_arg.xc — a return-type-only overload passed straight
// to a parameter takes the parameter's type.
//
// `Math.E()` has a float and a double form that differ only in return type,
// and the context chooses. An argument had no context: `check(Math.ln(Math.E()))`
// took the float `E` and the float `ln` (0.99999994, not 1.0), and the shipped
// compiler refused `check(Math.exp(Math.LN2()))` outright ("No method 'LN2'").
// A parameter every candidate agrees on is now the argument's context; where
// the candidates disagree (`Math.ln` itself) the outer context carries on down.

#import "Stdio.xc"
#import "Math.xc"

u32 testCount;
u32 failCount;

void check(double got, double want)
{
    testCount = testCount + 1;
    double diff = got - want;
    if (diff < 0.0d) { diff = 0.0d - diff; }
    if (diff > 0.000000001d) {
        Stdio.printf("T%u FAIL\n", testCount);
        failCount = failCount + 1;
    }
}

// Overloaded by return type only, like the Math constants.
float half(void)
{
    return 0.5;
}
i16 half(void)
{
    return (i16)50;
}

i16 twice(i16 v)
{
    return v + v;
}

class Acc : Object
{
    double total;
    void add(double v)
    {
        total = total + v;
    }
}

void main(void)
{
    testCount = 0;
    failCount = 0;

    check(Math.ln(Math.E()), 1.0d);                    // T1
    check(Math.exp(Math.LN2()), 2.0d);                 // T2
    check(Math.E(), 2.718281828459045d);               // T3
    check(Math.exp(Math.ln(Math.PI())), Math.PI());    // T4

    Acc* a = new Acc();
    a.add(Math.PI());
    a.add(Math.E());
    check(a.total, 5.859874482048838d);                // T5

    // The declaration's type still reaches through an argument whose
    // candidates disagree.
    double x = Math.ln(Math.E());
    check(x, 1.0d);                                    // T6

    // A user function: the i16 parameter picks the i16 overload.
    Stdio.printf("twice %d\n", twice(half()));

    // A cast is its operand's context (the float `E` gives -82 here).
    Stdio.printf("cast %ld\n", (i32)(((double)Math.E() - 2.718281828d) * 1000000000.0d));

    // No context at all: the float form, as before.
    Stdio.printf("e %ld\n", (i32)(Math.E() * 1000.0d));

    Stdio.printf("DONE %u\n", testCount);
    Stdio.printf("FAILED %u\n", failCount);
}
