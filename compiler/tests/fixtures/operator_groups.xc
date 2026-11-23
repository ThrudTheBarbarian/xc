// The arithmetic (+ - * / %), prefix (- + ~ !) and relational (< <= > >=)
// operators, each defined on a class. A relational operator returns whatever
// its method returns: here a Flag object, not a bool. Precedence is the
// built-in one throughout. operator_bitwise has the bitwise, shift and rotate
// operators (one fixture of all of them overflows the xt6502 code regions).
#import <Stdio.xc>

class Flag
    {
    i32 on;
    static Flag* of(bool b) { Flag* f = new Flag(); f.on = b ? 1 : 0; return f; }
    }

class Num
    {
    i32 v;
    static Num* of(i32 x) { Num* n = new Num(); n.v = x; return n; }
    Num* add(Num* o) :operator(self + o) { return Num.of(v + o.v); }
    Num* sub(Num* o) :operator(self - o) { return Num.of(v - o.v); }
    Num* mul(Num* o) :operator(self * o) { return Num.of(v * o.v); }
    Num* div(Num* o) :operator(self / o) { return Num.of(v / o.v); }
    Num* mod(Num* o) :operator(self % o) { return Num.of(v % o.v); }
    Num* neg()       :operator(-self)    { return Num.of(0 - v); }
    Num* pos()       :operator(+self)    { return Num.of(v < 0 ? 0 - v : v); }
    Num* inv()       :operator(~self)    { return Num.of(~v); }
    Num* not()       :operator(!self)    { return Num.of(v == 0 ? 1 : 0); }
    Flag* lt(Num* o) :operator(self < o)  { return Flag.of(v < o.v); }
    Flag* le(Num* o) :operator(self <= o) { return Flag.of(v <= o.v); }
    Flag* gt(Num* o) :operator(self > o)  { return Flag.of(v > o.v); }
    Flag* ge(Num* o) :operator(self >= o) { return Flag.of(v >= o.v); }
    }

i32 main(void)
    {
    Num* a = Num.of(12);
    Num* b = Num.of(5);
    Stdio.printf("+ %d\n", (a + b).v);
    Stdio.printf("- %d\n", (a - b).v);
    Stdio.printf("* %d\n", (a * b).v);
    Stdio.printf("/ %d\n", (a / b).v);
    Stdio.printf("%% %d\n", (a % b).v);
    Stdio.printf("prec %d\n", (a + b * a - b / b).v);
    Stdio.printf("neg %d\n", (-a).v);
    Stdio.printf("pos %d\n", (+(-a)).v);
    Stdio.printf("inv %d\n", (~a).v);
    Stdio.printf("not %d %d\n", (!a).v, (!(a - a)).v);
    Stdio.printf("< %d %d\n", (a < b).on, (b < a).on);
    Stdio.printf("<= %d %d\n", (a <= a).on, (a <= b).on);
    Stdio.printf("> %d %d\n", (a > b).on, (b > a).on);
    Stdio.printf(">= %d %d\n", (b >= b).on, (b >= a).on);
    Flag* f = a + b > a * b;
    Stdio.printf("mixed %d\n", f.on);
    return 0;
    }
