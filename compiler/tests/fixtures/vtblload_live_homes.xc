// vtblload_live_homes.xc — values live across `&obj.method` and a protocol
// method's address (respondsTo). On x86-64, r10 and r11 are caller-saved HOME registers;
// the vtable and itable loads behind `&c.take` / `&p.take` used them as
// scratch without counting as a call, so a value homed there across the
// load was overwritten. Enough values are live across each load that the
// allocator reaches r10/r11; each result must be what the arithmetic says.
// The loads use rcx and rdx instead, which carry the third and fourth
// arguments (SysV) or the first two (win64): calls of four arguments
// through a protocol and through a bound method, with a method's address
// tested inside the argument list, must pass every argument intact.
#import "Foundation.xc"
#import "Stdio.xc"

typedef void Sink(i32 v);
typedef i64 Four(i64 a, i64 b, i64 c, i64 d);

protocol Taker
{
    void take(i32 v);
    i64 four(i64 a, i64 b, i64 c, i64 d);
}

class C <Taker>
{
    i32 n;
    void init(void) { n = (i32)0; }
    void take(i32 v) { n = n + v; }
    i64 four(i64 a, i64 b, i64 c, i64 d) { return a + b * 10 + c * 100 + d * 1000; }
}

class D <Taker>
{
    i32 m;
    void take(i32 v) { m = m - v; }
    i64 four(i64 a, i64 b, i64 c, i64 d) { return a - b + c - d; }
}

i64 spin(C* c, Taker* p, i64 k)
{
    i64 a = k + 1; i64 b = k * 3; i64 d = k - 7; i64 e = k * k;
    i64 f = k + 11; i64 g = k * 5; i64 h = k - 13; i64 m = k + 17;
    i64 q = k * 9; i64 r = k + 23; i64 u = k - 29; i64 w = k * 7;
    i64 x = k + 31; i64 y = k * 11;
    // Every value above is live across both loads (respondsTo: the address
    // tested, nothing bound), and none across a call.
    i64 hits = 0;
    if (&c.take) { hits = hits + 1; }
    if (&p.take) { hits = hits + 2; }
    return a + b * 2 + d * 3 + e * 4 + f * 5 + g * 6 + h * 7 + m * 8
         + q * 9 + r * 10 + u * 11 + w * 12 + x * 13 + y * 14 + hits * 100;
}

i32 main(void)
{
    C* c = new C();
    i64 total = 0;
    D* dd = new D();
    for (i64 k = 0; k < 10; k = k + 1)
        total = total + spin(c, (k & 1) == 0 ? (Taker*)c : (Taker*)dd, k);
    Stdio.printf("total %ld\n", total);
    i64 calls = 0;
    for (i64 k = 0; k < 6; k = k + 1)
        {
        Taker* p = (k & 1) == 0 ? (Taker*)c : (Taker*)dd;
        calls = calls + p.four(k, (&c.take) ? 10 : 20, k * 3, (&p.four) ? 100 : 200);
        Four^ fb = &p.four;
        if (fb) { calls = calls + fb(k + 1, (&p.take) ? 2 : 3, k + 5, 7); }
        }
    Stdio.printf("calls %ld\n", calls);
    return 0;
}
