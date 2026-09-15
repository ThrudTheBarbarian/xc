// throw_method.xc — `throws` works on CLASS METHODS, not just free functions.
//
// It did not, when E1/E2 first landed: the flag was parsed but never reached the
// method. Three separate omissions from the free-function path, each silent in a
// different way —
//   * the parser did not copy throwsError onto XTMethodDeclNode, so `throw` in a
//     method body failed with "not declared 'throws'";
//   * the method's IR symbol lacked the `throws` attribute, so no call site
//     emitted an error check and the handler blocks were unreachable (the IR
//     verifier caught that, not a test);
//   * sema's effect flag tested isKindOfClass:XTFunctionDeclNode on the METHOD
//     path, where it is always false, so a `throws` method calling a throwing
//     function was wrongly rejected.
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

i32 mayFail(u32 n) throws
{
    if (n == (u32)1) throw new MyErr(String.withCString("mayfail"));
    return (i32)2;
}

class Worker
{
    u32 mode;
    void init(u32 v) { mode = v; }

    // throws from the method's own body
    i32 direct(void) throws
    {
        if (mode == (u32)1) throw new MyErr(String.withCString("method"));
        return (i32)9;
    }

    // a throws METHOD calling a throws FUNCTION, propagating without a try
    i32 viaCall(void) throws { return mayFail(mode); }
}

void main(void)
{
    Worker* ok  = new Worker((u32)0);
    Worker* bad = new Worker((u32)1);

    try { i32 a = ok.direct(); Stdio.printf("direct ok=%d\n", a); }
    catch (e) { Stdio.printf("UNEXPECTED\n"); }

    try { i32 b = bad.direct(); Stdio.printf("UNEXPECTED b=%d\n", b); }
    catch (MyErr e) { Stdio.printf("direct threw: %s\n", e.message().cString()); }

    try { i32 c = ok.viaCall(); Stdio.printf("via ok=%d\n", c); }
    catch (e) { Stdio.printf("UNEXPECTED\n"); }

    try { i32 d = bad.viaCall(); Stdio.printf("UNEXPECTED d=%d\n", d); }
    catch (MyErr e) { Stdio.printf("via threw: %s\n", e.message().cString()); }

    Stdio.printf("end\n");
}
