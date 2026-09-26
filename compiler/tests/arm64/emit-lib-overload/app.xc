// app.xc — the client of OvLib: a subclass that overrides one overload of
// each name, called through the base type from both sides of the boundary.
#import <OvLib>
#import "Stdio.xc"

class Circle : Shape
{
    void f(i32 x)
    {
        Stdio.printf("Circle.f(i32) %ld\n", x);
    }
    double v()
    {
        return 7.5d;
    }
}

void main(void)
{
    OvLib.numbers();
    Shape* s = new Circle();
    s.f((i32)1);
    s.f(1.5d);
    i32 i = s.v();
    double d = s.v();
    Stdio.printf("app v %ld %ld\n", i, (i32)(d * 10.0d));
    OvLib.poke(s);
    OvLib.poke(new Shape());
}
