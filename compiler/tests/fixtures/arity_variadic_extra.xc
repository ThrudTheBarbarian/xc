// A variadic callee accepts more arguments than its fixed parameters, called
// directly, as a static method, and through a function pointer whose typedef
// ends in `...`.
#import "Stdio.xc"

typedef void log_t(i32 n, ...);

void f(i32 n, ...) { Stdio.printf("f %ld\n", n); }

class K : Object
    {
    static void m(i32 n, ...) { Stdio.printf("m %ld\n", n); }
    }

void main(void)
    {
    f(1, 2, 3);
    K.m(4, 5);
    log_t@ p = &f;
    p(6);
    p(7, 8, 9);
    }
