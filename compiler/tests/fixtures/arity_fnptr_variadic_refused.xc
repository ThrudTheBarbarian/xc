//xtc-flags: expect=sema-error
// A variadic function-pointer type takes at least its fixed parameters.
// Refused: 'p' takes at least 1 argument; 0 given
#import "Stdio.xc"

typedef void log_t(i32 n, ...);

void f(i32 n, ...) { Stdio.printf("f %ld\n", n); }

void main(void)
    {
    log_t@ p = &f;
    p();
    }
