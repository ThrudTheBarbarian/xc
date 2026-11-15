// vtblload_live_homes.xc — values live across `&obj.method` and a protocol
// method's address (respondsTo). On x86-64, r10 and r11 are caller-saved HOME registers;
// the vtable and itable loads behind `&c.take` / `&p.take` used them as
// scratch without counting as a call, so a value homed there across the
// load was overwritten. Enough values are live across each load that the
// allocator reaches r10/r11; each result must be what the arithmetic says.
#import "Foundation.xc"
#import "Stdio.xc"

typedef void Sink(i32 v);

protocol Taker
{
    void take(i32 v);
}

class C <Taker>
{
    i32 n;
    void init(void) { n = (i32)0; }
    void take(i32 v) { n = n + v; }
}

class D <Taker>
{
    i32 m;
    void take(i32 v) { m = m - v; }
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
    return 0;
}
