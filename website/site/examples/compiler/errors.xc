// errors.xc — throws / try / catch / defer, worked end to end.
//
// A function that can fail says so with `throws`. Callers must either handle
// it in a `try` block or be declared `throws` themselves, so a failure path
// cannot be ignored by accident.
#import "Foundation.xc"
#import "Error.xc"      // not part of the Foundation umbrella
#import "Stdio.xc"

// Anything thrown must conform to `Error`, which requires message().
class ParseError <Error>
{
    String* _what;
    void init(void) { _what = 0; }
    static ParseError* with(String* what)
    {
        ParseError* e = new ParseError();
        e._what = what;
        return e;
    }
    String* message(void) { return _what; }
}

// `throws` is part of the signature: the caller can see it can fail.
u16 parseDigit(u8 c) throws
{
    if (c < (u8)'0' || c > (u8)'9')
        throw ParseError.with(String.withCString("not a digit"));
    return (u16)(c - (u8)'0');
}

// A `defer` block runs when the enclosing scope exits — on the normal path
// AND when an error unwinds through it. That is what makes it useful for
// releasing things.
u16 sumDigits(string s) throws
{
    defer { Stdio.print("  (defer: sumDigits scope exited)\n"); }
    u16 total = (u16)0;
    for (u16 i = (u16)0; s[i] != (u8)0; i = i + (u16)1)
        total = total + parseDigit(s[i]);       // may throw; propagates
    return total;
}

i32 main(void)
{
    // 1. The happy path. `try` guards the block; `catch (T e)` binds the
    //    error as a T. Name the class: an untyped `catch (e)` binds `e` as
    //    Object*, which has no message() — so it is only useful for "handle
    //    anything and carry on", not for inspecting what went wrong.
    try {
        u16 n = sumDigits("12345");
        Stdio.printf("sum of 12345 = %d\n", n);
    } catch (ParseError e) {
        Stdio.printf("unexpected: %s\n", e.message().cString());
    }

    // 2. The failing path — the throw unwinds out of the loop, out of
    //    sumDigits (running its defer), and lands in catch.
    try {
        u16 n = sumDigits("12x45");
        Stdio.printf("sum of 12x45 = %d\n", n);
    } catch (ParseError e) {
        Stdio.printf("caught: %s\n", e.message().cString());
    }

    // 3. The same, catching a throw that happens directly in the block.
    try {
        u16 d = parseDigit((u8)'!');
        Stdio.printf("digit %d\n", d);
    } catch (ParseError e) {
        Stdio.printf("caught a ParseError: %s\n", e.message().cString());
    }
    return 0;
}
