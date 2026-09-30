// Well-formed format strings stay silent: flags, width and precision in
// front of the right conversion, a `*` fed an integer, and `%%`. The length
// of an integer conversion need not match: it is fitted to the argument.
#use Stdio

i32 main(void)
    {
    double d = 1.5;
    float f = 2.5;
    i32 i = 3;
    i64 big = (i64)5;
    u8 b = (u8)65;
    u8* s = "hi";
    String* o = String.withFormat("%d %lld %c", big, i, b);
    Stdio.printf("%lf %.9lf %12lf %-8.3lf %e %g\n", d, d, d, d, d, f);
    Stdio.printf("%f %.2f %@\n", f, f, o);
    Stdio.printf("%.*lf %*ld\n", i, d, i, i);
    Stdio.printf("%+ld|%05ld|%s|%%|%x|%p\n", i, i, s, big, s);
    printf("%lf\n", d);
    return 0;
    }
