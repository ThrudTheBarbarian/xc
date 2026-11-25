// opprotomain.xc — the program half of opprotocols.sh. Built with -c and
// linked with opprotolib.o; it imports the library's interface, conforms a
// class of its own to the library's Numeric, and uses the protocol's
// operators on both classes.
#import "Stdio.xc"
#import <opprotolib>

class Score <Numeric>
    {
    i32 points;
    static Score* of(i32 p) { Score* s = new Score(); s.points = p; return s; }
    Numeric* plus(Numeric* other) :operator(self + other) { return Score.of(points + 10 * other.value()); }
    Numeric* pow(Numeric* e) :operator(self ** e) { return Score.of(points + e.value() + 1000); }
    Numeric* times(Numeric* o) :operator(self * o) { return Score.of(points * o.value() + 1); }
    i32 digit(i32 k) :operator(self[k]) { return k + points; }
    i32 size(void) :operator(|self|) { return 2 * points; }
    i32 value(void) { return points; }
    }

Numeric* sum3(Numeric* a, Numeric* b, Numeric* c)
    {
    return a + b + c;
    }

i32 main(void)
    {
    Numeric* m = Money.of(152);
    Numeric* s = Score.of(4);
    Stdio.printf("sum %d %d\n", sum3(m, s, m).value(), sum3(s, m, s).value());
    Stdio.printf("lib %d %d\n", sumOf(m, s).value(), sumOf(s, m).value());
    Numeric* two = Money.of(2);
    Numeric* three = Money.of(3);
    Stdio.printf("power %d %d\n", (three * two ** two ** three).value(), (s * s ** s).value());
    Stdio.printf("index %d %d %d\n", m[0], m[2], s[3]);
    Stdio.printf("bracket %d %d\n", |m| + |s|, 2 * |s|);
    return 0;
    }
