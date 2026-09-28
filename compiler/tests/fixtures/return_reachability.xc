// return_reachability.xc — the non-void fall-off warning's QUIET half.
//
// A non-void function that reaches its closing brace lowers to `Unreachable`
// and TRAPS at run time with no message. That is worth a compile-time
// warning (bug 553), but only if the warning is accurate: firing on a body
// that cannot actually fall through is worse than staying silent, so the
// analysis is deliberately conservative.
//
// This fixture pins the shapes that must NOT warn — an unbounded loop whose
// only exit is a `return`, and an if/else where both arms return — and then
// one body that DOES fall through, to show the warning does not fail the
// build or change the program. `maybe` is only ever called on its returning
// path, so its trap is never reached.
#import "Stdio.xc"

// `for (;;)` whose only exit is a return: cannot fall off the end.
i32 countTo(i32 limit)
{
    i32 n = 0;
    for (;;) {
        if (n >= limit) return n;
        n = n + 1;
    }
}

// `while (1)` with a return and no break: cannot fall off the end.
i32 doubleUp(i32 v)
{
    while (1) {
        if (v > 1000) return v;
        v = v * 2;
    }
}

// if / else where BOTH arms return: cannot fall off the end.
i32 sign(i32 x)
{
    if (x < 0) return -1;
    else if (x > 0) return 1;
    else return 0;
}

// A non-void body that CAN reach its closing brace: warned about, still built.
i32 maybe(i32 x)
{
    if (x) return x * 10;
}

void main(void)
{
    Stdio.printf("a=%d\n", countTo(5));
    Stdio.printf("b=%d\n", doubleUp(7));
    Stdio.printf("c=%d\n", sign(-3));
    Stdio.printf("d=%d\n", maybe(4));
}
