// half16b.xc — calls half16lib.c's functions without naming f16 or bf16: their
// types arrive from the library's debug information alone, and the program
// must still link the conversions printf's double needs. See run.sh.
#import "Stdio.xc"
#import <half16lib>

void main(void)
{
    Stdio.printf("h_add %g\n", h_add(1.5, 0.25));
    Stdio.printf("h_neg %g\n", h_neg(2));
    Stdio.printf("bf_id %g\n", bf_id(3.5));
}
