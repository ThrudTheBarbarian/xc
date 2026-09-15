// printf format-string checking. Each `Stdio.printf` / `printfAt`
// call whose format literal is compile-time visible has its
// specifiers matched against the supplied arg types.
//
// xtc: warn "Stdio.printf: '%f' expects float but argument 1 is double"
// xtc: warn "Stdio.printf: '%lf' expects double but argument 1 is float"
// xtc: warn "Stdio.printf: '%d' expects 16-bit signed integer but argument 1 is u32"
// xtc: warn "Stdio.printf: '%ld' expects 32-bit signed integer but argument 1 is double"
// xtc: warn "Stdio.printf: format string expects 1 argument, 0 supplied"
// xtc: warn "Stdio.printf: format string expects 0 arguments, 1 supplied"

#import "Stdio.xc"

void main(void)
{
    double d = 3.14d;
    float f = 1.5;
    u32 x = 1000000;

    Stdio.printf("%f\n", d);    // %f vs double
    Stdio.printf("%lf\n", f);   // %lf vs float
    Stdio.printf("%d\n", x);    // %d vs u32
    Stdio.printf("%ld\n", d);   // %ld vs double
    Stdio.printf("%s\n");       // missing arg
    Stdio.printf("\n", d);      // extra arg

    // Silent — these are correct:
    Stdio.printf("%f\n", f);
    Stdio.printf("%lf\n", d);
    Stdio.printf("%ld\n", x);
    Stdio.printf("plain\n");
}
