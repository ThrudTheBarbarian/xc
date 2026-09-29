//xtc-warn: Stdio.printf: '%f' expects float but argument 1 is double (use %lf for double)
//xtc-warn: Stdio.printf: '%.9f' expects float but argument 1 is double
//xtc-warn: Stdio.printf: '%12f' expects float but argument 2 is double
//xtc-warn: Stdio.printf: '%.*f' expects float but argument 2 is double
//xtc-warn: Stdio.printf: '%-8.3f' expects float but argument 1 is double
//xtc-warn: Stdio.printf: '%s' expects string but argument 1 is i32
//xtc-warn: Stdio.printf: format string expects 2 arguments, 1 supplied
//xtc-warn: printf (Stdio.printf via use): '%f' expects float but argument 1 is double
// The printf-format checker reads flags, width and precision before the
// conversion, and a `*` width or precision takes an argument of its own.
#use Stdio

i32 main(void)
    {
    double d = 1.5;
    i32 i = 3;
    Stdio.printf("%f\n", d);
    Stdio.printf("%.9f %12f\n", d, d);
    Stdio.printf("%.*f\n", i, d);
    Stdio.printf("%-8.3f|%+ld\n", d, i);
    Stdio.printf("%s\n", i);
    Stdio.printf("%ld %ld\n", i);
    printf("%f\n", d);
    return 0;
    }
