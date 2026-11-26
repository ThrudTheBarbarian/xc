// An integer literal at or above 2^63 is a u64: converted to a float it is
// about 1.8e19, not the -1 its bits spell as an i64 (#709). Its integer uses
// are unchanged.
#import "Stdio.xc"

f64 gD = (f64)$FFFFFFFFFFFFFFFF;

i32 main(void)
    {
    f64 d = (f64)$FFFFFFFFFFFFFFFF;
    f32 f = (f32)$FFFFFFFFFFFFFFFF;
    f64 e = (f64)$8000000000000000;
    f64 k = (f64)18446744073709551615;
    Stdio.printf("%g %g %g %g %g\n", d, (f64)f, e, k, gD);
    Stdio.printf("%g %g\n", (f64)$7FFFFFFFFFFFFFFF, (f64)$FFFFFFFF);
    u64 u = $FFFFFFFFFFFFFFFF;
    i64 s = $FFFFFFFFFFFFFFFF;
    u32 m = $FFFFFFFF;
    Stdio.printf("%lu %ld %u %d\n", u, s, m, $FFFFFFFFFFFFFFFF == u ? 1 : 0);
    return 0;
    }
