// throw_basic.xc — checked errors: `throws` / `throw` / `try` / `catch`.
//
// E1 of private:docs/Design/exceptions-and-defer.md. `throw` stores the error into the
// in-flight channel and returns after running every enclosing scope's defers and
// ARC teardown; a call to a `throws` function tests the channel and branches to
// the enclosing `catch`, or propagates if the caller is itself `throws`.
//
// Cases:
//   1. success path — the guarded block runs, handler does not
//   2. throw caught — handler runs, and can read message() via the protocol
//   3. propagation through an intermediate `throws` function with no try
//   4. defer runs on the throw path too, before the scope's ARC teardown
//   5. TYPED catch arms (E2) dispatch on the error's class, tested in source
//      order with the same RTTI check `(T@ ?)obj` uses
//   6. an error matching no typed arm reaches the untyped catch-all
//
// Output kept under 24 lines: the xt6502 console is 40x24.

#import "Stdio.xc"
#import "String.xc"
#import "Error.xc"

class MyErr <Error>
{
    String* msg;
    void init(String* m)  { msg = m; }
    String* message(void) { return msg; }
}

class IOErr <Error>
{
    String* msg;
    void init(String* m)  { msg = m; }
    String* message(void) { return msg; }
}

i32 typed(u32 n) throws
{
    if (n == (u32)1) throw new IOErr(String.withCString("io"));
    if (n == (u32)2) throw new MyErr(String.withCString("other"));
    return (i32)3;
}

i32 inner(u32 n) throws
{
    defer { Stdio.printf("  inner-defer\n"); }
    if (n == (u32)1) throw new MyErr(String.withCString("deep"));
    return (i32)7;
}

// No try here: the error propagates out to our caller.
i32 middle(u32 n) throws { i32 v = inner(n); return v + (i32)1; }

void main(void)
{
    try { i32 a = middle((u32)0); Stdio.printf("ok a=%d\n", a); }
    catch (e) { Stdio.printf("UNEXPECTED\n"); }

    try { i32 b = middle((u32)1); Stdio.printf("UNEXPECTED b=%d\n", b); }
    catch (e) { Stdio.printf("caught: %s\n", ((MyErr*)e).message().cString()); }

    // typed arms: IOErr hits its own arm, MyErr falls through to the catch-all
    try { i32 c = typed((u32)1); Stdio.printf("UNEXPECTED c=%d\n", c); }
    catch (IOErr e) { Stdio.printf("io-arm: %s\n", e.message().cString()); }
    catch (e)       { Stdio.printf("UNEXPECTED all\n"); }

    try { i32 d = typed((u32)2); Stdio.printf("UNEXPECTED d=%d\n", d); }
    catch (IOErr e) { Stdio.printf("UNEXPECTED io\n"); }
    catch (e)       { Stdio.printf("fallback\n"); }

    Stdio.printf("end\n");
}
