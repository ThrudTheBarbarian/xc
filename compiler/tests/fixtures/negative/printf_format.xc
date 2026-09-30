// printf format-string checking. Each `Stdio.printf` / `printfAt`
// call whose format literal is compile-time visible has its
// conversions matched against the KIND of each argument; the length
// of an integer conversion is sized to its argument, so it never warns.
//
// xtc: warn "Stdio.printf: '%d' expects an integer but argument 1 is double"
// xtc: warn "Stdio.printf: '%lf' expects a floating-point value but argument 1 is u32"
// xtc: warn "Stdio.printf: '%s' expects a string but argument 1 is float"
// xtc: warn "Stdio.printf: format string expects 1 argument, 0 supplied"
// xtc: warn "Stdio.printf: format string expects 0 arguments, 1 supplied"

#import "Stdio.xc"

void main(void)
{
    double d = 3.14d;
    float f = 1.5;
    u32 x = 1000000;

    Stdio.printf("%d\n", d);    // %d vs double
    Stdio.printf("%lf\n", x);   // %lf vs u32
    Stdio.printf("%s\n", f);    // %s vs float
    Stdio.printf("%s\n");       // missing arg
    Stdio.printf("\n", d);      // extra arg

    // Silent — these are correct:
    Stdio.printf("%f\n", f);
    Stdio.printf("%lf\n", d);
    Stdio.printf("%d %ld %lld\n", x, x, x);
    Stdio.printf("plain\n");
}
