// Every ordered comparison with a NaN is false, and != is true, for float and
// double alike (#695): xt6502's math coprocessor answers 0 for an unordered
// pair as it does for an equal one, so a NaN compared equal to itself there.
#import "Stdio.xc"

float ffrom(u32 u) { return *(float*)&u; }
double dfrom(u64 u) { return *(double*)&u; }

i32 b(bool x) { return x ? 1 : 0; }

i32 main(void)
    {
    float n = ffrom($7FC00000);
    float one = 1.0;
    Stdio.printf("f32 nan: %d %d %d %d %d %d\n", b(n == n), b(n != n), b(n < one), b(n <= one), b(n > one), b(n >= one));
    Stdio.printf("f32 one: %d %d %d %d %d %d\n", b(one == one), b(one != one), b(one < one), b(one <= one), b(one > one), b(one >= one));
    double dn = dfrom($7FF8000000000000);
    double d1 = 2.0;
    Stdio.printf("f64 nan: %d %d %d %d %d %d\n", b(dn == dn), b(dn != dn), b(d1 < dn), b(d1 <= dn), b(d1 > dn), b(d1 >= dn));
    Stdio.printf("f64 two: %d %d %d %d\n", b(d1 == d1), b(d1 != d1), b(d1 <= d1), b(d1 >= d1));
    return 0;
    }
