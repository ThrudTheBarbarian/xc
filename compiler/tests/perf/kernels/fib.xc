// fib.xc — naive recursive Fibonacci.
// Exercises: function-call overhead, prologue/epilogue, no memory traffic.
#import <Stdio.xc>

i32 fib(i32 n)
    {
    if (n < 2)
        return n;
    return fib(n - 1) + fib(n - 2);
    }

void main(void)
    {
    i32 s = 0;
    for (i32 k = 0; k < 30; k++)
        s += fib(16) & $F; // fib(16) = 987
    Stdio.printf("%ld\n", s);
    }
