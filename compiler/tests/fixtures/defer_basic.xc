// defer_basic.xc — `defer { ... }` runs when the enclosing scope exits, by ANY
// path, last-registered-first, and BEFORE that scope's ARC releases.
//
// defer is a STATEMENT, not a value: the body is lowered inline at each exit of
// the scope that registered it, so nothing is captured and nothing allocated —
// which is how the language gets defer without having closures. See
// private:docs/Design/exceptions-and-defer.md §4.
//
// Output is deliberately kept under 24 lines: the xt6502 console is 40x24, and
// a longer fixture scrolls, which dumps screen RAM into the captured output.
//
// The cases below are the ones that distinguish a real implementation:
//   1. LIFO order within a scope
//   2. runs on an EARLY return and on the fall-through return, once each
//   3. runs on the `break` path out of a loop
//   4. runs on the `continue` path
//   5. inner scope's defer runs at the inner brace, outer at function exit
//   6. runs BEFORE the scope's ARC teardown — the body must still be able to
//      use the local it was written to clean up

#import "Stdio.xc"

class Res
{
    u32 id;
    void init(u32 v)   { id = v; }
    void dealloc(void) { Stdio.printf("dealloc %d\n", id); }
}

u32 early(u32 n)
{
    defer { Stdio.printf("  defer-in-early\n"); }
    if (n == (u32)1) return (u32)10;
    return (u32)20;
}

void main(void)
{
    // 1. LIFO
    {
        defer { Stdio.printf("  A\n"); }
        defer { Stdio.printf("  B\n"); }
        Stdio.printf("  body\n");
    }

    // 2. both return paths, exactly once each
    Stdio.printf("  got %d\n", early((u32)1));
    Stdio.printf("  got %d\n", early((u32)0));

    // 3. break
    for (u32 i = (u32)0; i < (u32)3; i = i + (u32)1) {
        defer { Stdio.printf("  d%d\n", i); }
        if (i == (u32)1) break;
    }

    // 4. continue
    for (u32 i = (u32)0; i < (u32)3; i = i + (u32)1) {
        defer { Stdio.printf("  c%d\n", i); }
        if (i == (u32)1) continue;
        Stdio.printf("  body%d\n", i);
    }

    // 5. nesting: inner at the inner brace, outer at function exit
    defer { Stdio.printf("  outer-at-exit\n"); }
    {
        defer { Stdio.printf("  inner\n"); }
        Stdio.printf("  in-block\n");
    }

    // 6. ordering against ARC: the body still sees `r`
    {
        Res* r = new Res((u32)7);
        defer { Stdio.printf("  defer sees id=%d\n", r.id); }
    }
    Stdio.printf("end\n");
}
