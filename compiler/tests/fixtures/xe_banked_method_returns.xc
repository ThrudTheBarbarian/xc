// xe_banked_method_returns.xc — Phase 1c: wider return-types from
// `:banked` heap-class methods. Each return convention parks its
// result in a different way ($B0..$B7 for struct/float, A/X +
// u32HiReg for u32, A/X for class pointer); the cloaked-bracket
// method-call wrapper preserves only A across the PORTB restore,
// so wider returns must travel through $B0..$B7 (which the
// wrapper doesn't touch) or through u32HiReg.

#import "Stdio.xc"
#import "Assert.xc"

struct Pair { u16 a; u16 b; }

class Maker
{
    u16 base;
    float fac;
    u32  bigBase;

    void seed(u16 b, float f, u32 g) :banked
    {
        base = b;
        fac = f;
        bigBase = g;
    }

    Pair  makePair(u16 v) :banked
    {
        Pair p;
        p.a = v;
        p.b = v + base;
        return p;
    }

    float scale(float v) :banked  { return v * fac; }

    u32 addBig(u32 v) :banked     { return bigBase + v; }
}

void main(void)
{
    Assert.reset();
    Maker* m = new Maker();
    m.seed(100, 2.0, (u32)$10000);

    Pair r = m.makePair(7);
    Assert.isEqual(r.a, 7);
    Assert.isEqual(r.b, 107);

    float f = m.scale(3.5);
    Assert.isTrue(f > 6.99);
    Assert.isTrue(f < 7.01);

    u32 big = m.addBig((u32)$2345);
    Assert.isEqual(big, (u32)$12345);

    Assert.summary();
    return;
}
