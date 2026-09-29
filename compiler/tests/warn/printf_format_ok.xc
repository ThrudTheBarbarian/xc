// Well-formed format strings stay silent: flags, width and precision in
// front of the right conversion, a `*` fed an integer, and `%%`.
#use Stdio

i32 main(void)
    {
    double d = 1.5;
    float f = 2.5;
    i32 i = 3;
    u8* s = "hi";
    Stdio.printf("%lf %.9lf %12lf %-8.3lf\n", d, d, d, d);
    Stdio.printf("%f %.2f\n", f, f);
    Stdio.printf("%.*lf %*ld\n", i, d, i, i);
    Stdio.printf("%+ld|%05ld|%s|%%\n", i, i, s);
    printf("%lf\n", d);
    return 0;
    }
