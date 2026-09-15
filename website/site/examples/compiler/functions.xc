// functions.xc — overloading, multiple return values, tuple unpacking,
// varargs, and recursion.
#import "Foundation.xc"
#import "Stdio.xc"

// ---- Overloading -----------------------------------------------------------
// Same name, different parameter types. The compiler picks by argument type,
// scoring conversions so the closest match wins.
u16 area(u16 side)             { return side * side; }
u16 area(u16 w, u16 h)         { return w * h; }
float area(float radius)       { return 3.14159 * radius * radius; }

// ---- Multiple return values ------------------------------------------------
// A function may return several values: the return types are a comma-separated
// list before the name, and `return` takes a matching list. The CALL SITE
// parenthesises, not the declaration.
u16, u16 divmod(u16 n, u16 d)
{
    return n / d, n % d;
}

// Three, of mixed type — the list is not restricted to one width.
u16, u16, bool minMax(u16 a, u16 b)
{
    if (a <= b) return a, b, true;
    return b, a, false;
}

// ---- Varargs ---------------------------------------------------------------
// `...` after the fixed parameters. The cursor is a plain `u8` that `va_start`
// initialises — there is no `va_list` type and no `va_end`. Each argument is
// read with a WIDTH-NAMED accessor (`va_arg_u16`, `va_arg_i32`, `va_arg_double`,
// `va_arg_ptr`, …) rather than a type parameter, and as in C the count has to
// come from somewhere — here a leading argument.
u32 sumOf(u16 count, ...)
{
    u32 total = (u32)0;
    u8  ap;
    va_start(ap);
    for (u16 i = (u16)0; i < count; i = i + (u16)1)
        total = total + (u32)va_arg_u16(ap);
    return total;
}

// ---- Recursion -------------------------------------------------------------
// Self-recursion is ordinary. At -O2 and above a TAIL call becomes a loop, so
// this costs no stack depth per step.
u32 factorial(u16 n)
{
    if (n <= (u16)1) return (u32)1;
    return (u32)n * factorial(n - (u16)1);
}

// A default-free "out parameter" is just a pointer.
void bump(u16* slot, u16 by) { *slot = *slot + by; }

// A pure FORWARDER: it declares `...`, reads none of its own arguments, and
// passes the tail on with `...` in the argument position. Both rules are
// checked — a function that called `va_start` here could not also forward.
void logf(string fmt, ...)
{
    Stdio.print("[log] ");
    Stdio.printf(fmt, ...);
}

i32 main(void)
{
    // Overloads resolve on the argument types.
    Stdio.printf("area square %d, rect %d, circle %f\n",
                 area((u16)5), area((u16)3, (u16)4), area(2.0));

    // Tuple unpacking: declare the variables, then assign the call to them
    // as a parenthesised list.
    u16 q, r;
    (q, r) = divmod((u16)17, (u16)5);
    Stdio.printf("17/5 = %d rem %d\n", q, r);

    u16 lo, hi;
    bool ordered;
    (lo, hi, ordered) = minMax((u16)9, (u16)4);
    Stdio.printf("minMax(9,4) = %d %d ordered=%d\n",
                 lo, hi, ordered ? (u16)1 : (u16)0);

    // Varargs.
    Stdio.printf("sum %ld\n", sumOf((u16)4, (u16)10, (u16)20, (u16)30, (u16)40));

    // Forwarding the whole variadic tail — the wrapper C needs a v-variant for.
    logf("forwarded a=%d s=%s\n", (u16)222, "hi");

    // Recursion.
    Stdio.printf("10! = %ld\n", factorial((u16)10));

    // Out parameter.
    u16 counter = (u16)100;
    bump(&counter, (u16)5);
    Stdio.printf("counter %d\n", counter);
    return 0;
}
