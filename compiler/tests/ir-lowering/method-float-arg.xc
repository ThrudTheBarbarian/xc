// method-float-arg — scalar arguments to an instance method's `double`
// parameter. Crossing between the integer and float domains is a
// CONVERSION (SIToFp / UIToFp), and an in-domain float widen is FpExt —
// never an integer ZExt, which would hand the callee an integer's bit
// pattern where it reads a float. Covers a float literal, a `d`-suffixed
// double literal, a float local, a signed int local and an unsigned int
// local.
class C
    {
    i32 pad;

    double m(double d)
        {
        return d;
        }

    double run(float fl, i32 si, u32 ui)
        {
        double a = m(2.0);   // float literal -> FpExt
        double b = m(2.0d);  // double literal -> as-is
        double c = m(fl);    // float local   -> FpExt
        double d = m(si);    // i32 local     -> SIToFp
        double e = m(ui);    // u32 local     -> UIToFp
        return a + b + c + d + e;
        }
    }
