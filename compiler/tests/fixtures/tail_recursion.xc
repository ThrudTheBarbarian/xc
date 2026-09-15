// tail_recursion.xc — exercises the arm64 recursion→loop transform
// (XTIROptTailRecursion). On arm64 -O2 these self-recursions are
// rewritten to loops (Tier 2: accumulator recursion fib; Tier 1: true
// tail self-call sumto); on xt6502 they stay as ordinary recursion.
// Both backends must produce identical numbers, matched against the
// legacy AST-codegen oracle. Output is kept under one Atari screen
// (no scroll) so the screen-rendered oracle stays clean.

#import "Stdio.xc"

// Tier 2 — accumulator recursion: g ⊕ self-call with ⊕ = + (the
// classic fib(n-1)+fib(n-2), one call iterated to a loop).
i32 fib(i32 n)
{
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

// Tier 1 — true tail self-call threading an accumulator parameter.
i32 sumto(i32 n, i32 acc)
{
    if (n == 0) return acc;
    return sumto(n - 1, acc + n);
}

void main(void)
{
    for (i32 i = 0; i <= 12; i = i + 1)
        Stdio.printf("fib(%ld)=%ld\n", i, fib(i));
    for (i32 i = 0; i <= 6; i = i + 1)
        Stdio.printf("sumto(%ld)=%ld\n", i, sumto(i, 0));
}
