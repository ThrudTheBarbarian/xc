// class_property.xc — property-accessor rewrites.
//
//   T1  Both getter `full()` and setter `setFull(T)` defined.
//       `b.full = 7` routes through `setFull`, `b.full` through `full()`.
//   T2  Getter only. Writes fall through to direct ivar store; reads
//       route through the getter (which biases the read by +100).
//   T3  Setter only. Reads fall through to direct ivar load; writes
//       route through the setter (which biases the write by +50).
//   T4  Neither accessor defined. Baseline direct ivar access is
//       unchanged — proves the feature is opt-in.
//   T5  Compound assignment through a setter desugars to
//       `x.prop = x.prop OP v`: getter runs on the read side,
//       setter runs on the write side, once per statement.

#import "Stdio.xc"

class Both {
    u8 _full;
    u8 getCalls;
    u8 setCalls;
    void init(void)     { _full = 0; getCalls = 0; setCalls = 0; }
    u8   full(void)     { getCalls = getCalls + 1; return _full; }
    void setFull(u8 v)  { setCalls = setCalls + 1; _full = v; }
}

class GetOnly {
    u8 n;
    u8 getCalls;
    void init(void)     { n = 0; getCalls = 0; }
    u8   n(void)        { getCalls = getCalls + 1; return n + 100; }
}

class SetOnly {
    u8 n;
    u8 setCalls;
    void init(void)     { n = 0; setCalls = 0; }
    void setN(u8 v)     { setCalls = setCalls + 1; n = v + 50; }
}

class Plain {
    u8 n;
    void init(void)     { n = 0; }
}

// Getter + clamping setter for the compound-assignment test.
class Clamp {
    u8 _v;
    u8 getCalls;
    u8 setCalls;
    void init(void)     { _v = 0; getCalls = 0; setCalls = 0; }
    u8   v(void)        { getCalls = getCalls + 1; return _v; }
    void setV(u8 x)     {
        setCalls = setCalls + 1;
        if (x > 100) x = 100;
        _v = x;
    }
}

void main(void)
{
    Both* b = new Both();
    b.full = 7;
    u8 r1 = b.full;
    if (r1 == 7 && b.getCalls == 1 && b.setCalls == 1) {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL r=%d g=%d s=%d\n", r1, b.getCalls, b.setCalls);
    }

    GetOnly* g = new GetOnly();
    g.n = 5;
    u8 r2 = g.n;
    if (r2 == 105 && g.getCalls == 1) {
        Stdio.printf("T2 PASS\n");
    } else {
        Stdio.printf("T2 FAIL r=%d g=%d\n", r2, g.getCalls);
    }

    SetOnly* s = new SetOnly();
    s.n = 5;
    u8 r3 = s.n;
    if (r3 == 55 && s.setCalls == 1) {
        Stdio.printf("T3 PASS\n");
    } else {
        Stdio.printf("T3 FAIL r=%d s=%d\n", r3, s.setCalls);
    }

    Plain* p = new Plain();
    p.n = 42;
    if (p.n == 42) {
        Stdio.printf("T4 PASS\n");
    } else {
        Stdio.printf("T4 FAIL r=%d\n", p.n);
    }

    // T5: compound assignment through setter — desugars into
    // `c.v = c.v + x` (getter on the read side, setter on the
    // write side) and the setter's clamp keeps the final value
    // at 100 when the raw sum overflows that.
    Clamp* c = new Clamp();
    c.v = 10;       // setter, _v=10
    c.v += 5;       // desugar: getter=10, +5=15, setter; _v=15
    c.v += 20;      // desugar: getter=15, +20=35, setter; _v=35
    c.v += 80;      // desugar: getter=35, +80=115, clamp; _v=100
    u8 finalV = c.v;
    u8 gc = c.getCalls;
    u8 sc = c.setCalls;
    if (finalV == 100 && gc == 4 && sc == 4) {
        Stdio.printf("T5 PASS\n");
    } else {
        Stdio.printf("T5 FAIL v=%d g=%d s=%d\n", finalV, gc, sc);
    }
}
