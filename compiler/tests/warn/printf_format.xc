//xtc-warn: Stdio.printf: '%d' expects an integer but argument 1 is double
//xtc-warn: Stdio.printf: '%12f' expects a floating-point value but argument 2 is i32
//xtc-warn: Stdio.printf: '%.*f' expects a floating-point value but argument 2 is i32
//xtc-warn: Stdio.printf: '%s' expects a string but argument 1 is i32
//xtc-warn: Stdio.printf: format string expects 2 arguments, 1 supplied
//xtc-warn: String.withFormat: '%@' expects an object but argument 1 is i32
//xtc-warn: printf (Stdio.printf via use): '%x' expects an integer but argument 1 is double
// The printf-format checker reads flags, width and precision before the
// conversion, and a `*` width or precision takes an argument of its own.
// Sizes are fitted to the arguments, so only a wrong KIND is reported.
#use Stdio

i32 main(void)
    {
    double d = 1.5;
    i32 i = 3;
    Stdio.printf("%d\n", d);
    Stdio.printf("%.9f %12f\n", d, i);
    Stdio.printf("%.*f\n", i, i);
    Stdio.printf("%s\n", i);
    Stdio.printf("%ld %ld\n", i);
    String* s = String.withFormat("%@", i);
    printf("%x\n", d);
    return 0;
    }
