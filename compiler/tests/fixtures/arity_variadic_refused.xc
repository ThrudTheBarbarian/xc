//xtc-flags: expect=sema-error
// A variadic function takes AT LEAST its fixed parameters. Fewer is refused;
// more is the point of `...` (see arity_variadic_extra.xc).
// Refused: 'f' takes at least 1 argument; 0 given
#import "Stdio.xc"

void f(i32 n, ...) { Stdio.printf("f %ld\n", n); }

void main(void)
    {
    f();
    }
