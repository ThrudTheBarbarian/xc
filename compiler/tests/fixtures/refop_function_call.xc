// refop_function_call.xc — `delete` / `retain` / `release` as
// user-defined free function names.
//
// The refop keywords (`delete <expr>;` / `retain <expr>;` /
// `release <expr>;`) historically blocked the same names as
// free functions: at statement position the parser always took
// the refop branch, so `delete(40, 2);` silently parsed as
// "refcount-delete the value of `(40, 2)`" — sema then failed
// on the comma operator.
//
// looksLikeRefopFunctionCall: scans from the keyword to the
// matching `)`. If contents are empty (`delete()`) or contain a
// top-level comma (`delete(40, 2)`), the refop interpretation
// can't fit — refop's operand is a single expression — so the
// parser falls through to the expression-statement path. The
// matching expression-parser case treats XTTokenDelete /
// Retain / Release as identifiers when followed by `(`.
//
// Single-arg `delete(p);` at statement level remains ambiguous
// and stays as the refop, preserving existing fixtures like
// heap_basic's `delete (Box@)0;` (the parens here are a cast
// + literal, not a function call). Users who define a single-
// arg free function named `delete` should rename it or call
// via `inline:delete(p);` (which forces the expression-parser
// branch).
//
// Expression-position calls (e.g. `Assert.isEqual(retain(21),
// 42);`) work for any arity since there's no refop ambiguity
// outside statement position.

#import "Stdio.xc"
#import "Assert.xc"

u16 delete(u16 a, u16 b)
{
    return a + b;
}

u16 retain(u16 a)
{
    return a * 2;
}

u16 release(u8 a, u8 b, u8 c)
{
    return (u16)a + (u16)b + (u16)c;
}

void main(void)
{
    Assert.reset();

    // Expression-position: any arity works.
    Assert.isEqual(delete(40, 2), 42);     // T1
    Assert.isEqual(retain(21), 42);        // T2
    Assert.isEqual(release(10, 15, 17), 42); // T3

    // Statement-position: zero or 2+ args parse as function call.
    u16 sum = 0;
    delete(sum, 5);   // sum unchanged; just verifies it parses + runs
    Assert.isEqual(sum, 0);                // T4

    Assert.summary();
    return;
}
