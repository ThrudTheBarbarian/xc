// OvLib.xc — a library whose classes overload by parameter and by return
// type. In a library build every instance method is a vtable root, so every
// overload has its own slot, and a call has to use the one it resolved to.
#import "Stdio.xc"
#import "Number.xc"

class Shape : Object
{
    void f(i32 x)
    {
        Stdio.printf("Shape.f(i32) %ld\n", x);
    }
    void f(double d)
    {
        Stdio.printf("Shape.f(double) %ld\n", (i32)(d * 10.0d));
    }
    i32 v()
    {
        return 1;
    }
    double v()
    {
        return 2.5d;
    }
}

class OvLib : Object
{
    // Number's ten `value()` overloads differ only in return type.
    static void numbers(void)
    {
        Number* n = Number.with((i64)5000000000);
        i64 a = n.value();
        double c = n.value();
        Number* m = Number.with((i32)77);
        i32 b = m.value();
        Stdio.printf("lib numbers %lld %ld %ld\n", a, b, (i32)(c / 1000.0d));
    }
    // Class-typed calls inside the library, on whatever subclass the client
    // passes in.
    static void poke(Shape* s)
    {
        s.f((i32)4);
        s.f(4.5d);
        i32 i = s.v();
        double d = s.v();
        Stdio.printf("lib v %ld %ld\n", i, (i32)(d * 10.0d));
    }
}
