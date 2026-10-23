// A try whose body cannot raise has no reachable handler; the reference's
// verifier rejected the catch block ("unreachable from entry", §12.10) where
// the port accepted it. Now neither lowers the arms. And a `throw` inside a
// try in the same function goes to that try's handler in both compilers (the
// reference returned instead, skipping the local catch).
#import "Stdio.xc"
#import "Error.xc"

class Oops : Object <Error> { String* message(void) { return String.withCString("oops"); } }
class Quiet : Object { u32 n; void run(void) { n = n + (u32)1; } }

u32 maybe(u32 v) throws
    {
    if (v > (u32)3)
        throw new Oops();
    return v * (u32)10;
    }

i32 local(void) throws
    {
    try { throw new Oops(); } catch (e) { return 1; }
    return 2;
    }

i32 main(void)
    {
    Quiet* q = new Quiet();
    try { q.run(); } catch (e) { Stdio.printf("never\n"); }
    Stdio.printf("quiet ran %u\n", q.n);

    i32 r = 0;
    try { r = local(); } catch (e) { r = 3; }
    Stdio.printf("local catch %d\n", r);

    u32 got = (u32)0;
    try
        {
        try { q.run(); } catch (e) { Stdio.printf("inner never\n"); }
        got = maybe((u32)2) + maybe((u32)9);
        }
    catch (e)
        {
        Stdio.printf("outer caught, got %u, quiet %u\n", got, q.n);
        }
    return 0;
    }
