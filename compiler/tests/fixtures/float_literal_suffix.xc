// float_literal_suffix.xc — the `f`/`F` and `d`/`D` literal suffixes.
//
// A trailing `f`/`F` makes a literal a single-precision `float`; `d`/`D` makes
// it a `double`. Either will do so without a radix point, so `1f` and `1d` are
// floating point numbers and not an integer followed by an identifier. The
// suffixes are C's and Java's spellings, so a table of constants copied from
// either compiles as it stands instead of producing one "Undefined identifier
// 'f'" per row.
//
// A literal with NO suffix is a float, whatever it is assigned to (see
// language/lexical.md); every value here is exactly representable, so the
// back end or the printf rounding cannot change the answer.
#import "Stdio.xc"

// The shape that provoked this: a table of scale factors, every row suffixed.
float gScale[4] = { 0.68, 0.5f, 1f, 2F };

float half(void)
{
    return 0.5f;
}

i32 main(void)
{
    // A suffix on a literal with a radix point, and one without.
    float a = 0.5f;
    float b = 1F;
    double c = 2.5d;
    double d = 4D;

    // The suffix decides the WIDTH, with or without a radix point. sizeof is
    // the check no rounding can blur: 4, 4, 8, 8.
    Stdio.printf("%d %d %d %d\n", (i32)sizeof(a), (i32)sizeof(b),
                 (i32)sizeof(c), (i32)sizeof(d));

    // The value is what it always was; only the width changed.
    Stdio.printf("%f %f %f %f\n", a, b, (float)c, (float)d);

    // The suffixed table, printed as stored.
    Stdio.printf("%f %f %f %f\n", gScale[0], gScale[1], gScale[2], gScale[3]);

    // Suffixes inside an expression, on both sides.
    Stdio.printf("%f %f\n", 0.5f * 4f, half() + (float)1d);

    // `f` is still an ordinary identifier when it is not glued to a number.
    i32 f = 7;
    Stdio.printf("%d\n", f);
    return (i32)0;
}
