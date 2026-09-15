// Calls its `^` UNGUARDED on purpose: this fixture pins the call mechanism
// itself, with a receiver that is alive throughout, so -Wunguarded-action
// fires here BY DESIGN. Not suppressed with a //xtc-flags: line, because
// the sweep honours only structured directives (target=/skip/na/expect=)
// and would silently ignore a -W flag — the warning goes to stderr and the
// sweep compares stdout, so it costs nothing.
// bound_method_nullcmp.xc — comparing a bound method (`^`) against null.
//
// A `^` is a two-word PAIR, so `f == 0` lowers to "compare both halves, AND
// the results". The trap is that sema types a COMPARISON as the widening of
// its operands, so `f == (Sink^)0` is itself typed `^` — and the condition
// lowering used to read that AST type and extract field 0 from the Bool the
// comparison had already produced. The extracted garbage made `f == 0` and
// `f != 0` BOTH true on win64 (arm64 tolerated the bad instruction), so every
// `if (cb == 0) return;` guard took the early return and every optional
// callback silently did nothing.
//
// All four spellings are checked, on a live pair and a null one, because the
// bug was invisible in the `if (h)` form that most code uses.
#import "Foundation.xc"
#import "Stdio.xc"

typedef void Sink(i32 v);

class C : Object
{
    i32 n;
    void init(void) { n = (i32)0; }
    void take(i32 v) { n = n + v; }
}

i32 main(void)
{
    C* c = new C();
    Sink^ f = &c.take;          // live: recv = c, code = C.take
    Sink^ z = (Sink^)0;         // null pair

    f((i32)5);
    Stdio.printf("callable %d\n", (i16)c.n);
    Stdio.printf("f  eq %d ne %d if %d not %d\n",
                 (i16)(f == (Sink^)0 ? 1 : 0), (i16)(f != (Sink^)0 ? 1 : 0),
                 (i16)(f ? 1 : 0), (i16)(!f ? 1 : 0));
    Stdio.printf("z  eq %d ne %d if %d not %d\n",
                 (i16)(z == (Sink^)0 ? 1 : 0), (i16)(z != (Sink^)0 ? 1 : 0),
                 (i16)(z ? 1 : 0), (i16)(!z ? 1 : 0));

    // The shape that actually broke in the field: guard, then call.
    if (f == (Sink^)0) { Stdio.print("BAD callable looks null\n"); }
    else               { f((i32)3); Stdio.printf("guarded call ok %d\n", (i16)c.n); }
    if (z != (Sink^)0) { Stdio.print("BAD null looks callable\n"); }
    else               { Stdio.print("null guarded ok\n"); }
    return 0;
}
