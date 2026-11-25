// Operator requirements from an interface: a class conforms to the imported
// protocol, and `a * b ** c ** d` and `|a|` on protocol values resolve to the
// protocol's methods with the precedence the interface gives.
#import "Stdio.xc"
#import <mod-opproto>
class N <Num>
    {
    i32 v;
    static N* of(i32 x)
        {
        N* n = new N();
        n.v = x;
        return n;
        }
    Num* plus(Num* o) :operator(self + o) { return N.of(v + o.value()); }
    Num* raise(Num* e) :operator(self ** e) { return N.of(v * 10 + e.value()); }
    Num* times(Num* o) :operator(self * o) { return N.of(v * o.value()); }
    i32 size() :operator(|self|) { return v < 0 ? 0 - v : v; }
    i32 value() { return v; }
    }
void main(void)
    {
    Num* a = N.of(1);
    Num* b = N.of(2);
    Num* c = N.of(3);
    Stdio.printf("%d %d\n", (a * b ** c ** a + c).value(), |N.of(-5)| + |a|);
    return;
    }
