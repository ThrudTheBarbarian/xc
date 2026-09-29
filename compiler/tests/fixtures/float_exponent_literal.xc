// Float literals with a decimal exponent, with or without a point and with
// either suffix. `e` only belongs to the number when digits follow it.
#use Stdio

i32 main(void)
    {
    float a = 1e9;
    double b = 2.5e-3d;
    double c = 1.5E+2d;
    float d = 4E2f;
    u32 e = (u32)7;
    Stdio.printf("%lu %lu %lu %lu\n", (u32)a, (u32)(b * 1000000.0d), (u32)c, (u32)d);
    Stdio.printf("%lu\n", e);
    return 0;
    }
