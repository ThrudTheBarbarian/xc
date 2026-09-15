// arc_break_continue_scope.xc — a strong local declared in a loop body is
// released when the loop is left by `break` or `continue`, not only when the
// body falls off its end.
//
// It used to leak on both paths. `break`/`continue` set a terminator without
// emitting any ARC teardown, and lowerBlockStmt then saw that terminator and
// dropped the scope with emitReleases:NO — on the assumption (true only of
// `return`) that whatever set the terminator had already released. So every
// strong local in a loop body leaked whenever the loop was exited early.
//
// Each object must be deallocated exactly once: a missing line is the leak,
// a doubled line is the over-release the fix must not introduce.

#import "Stdio.xc"

class Res
{
    u32 id;
    void init(u32 v)   { id = v; }
    void dealloc(void) { Stdio.printf("dealloc %d\n", id); }
}

void main(void)
{
    // break out of a for-loop: 1 must be released on the break path
    Stdio.printf("-- for/break\n");
    for (u32 i = (u32)0; i < (u32)3; i = i + (u32)1) {
        Res* r = new Res(i);
        if (i == (u32)1) break;
    }

    // continue: 11 must be released on the continue path
    Stdio.printf("-- for/continue\n");
    for (u32 i = (u32)10; i < (u32)13; i = i + (u32)1) {
        Res* r = new Res(i);
        if (i == (u32)11) continue;
    }

    // while + break
    Stdio.printf("-- while/break\n");
    u32 j = (u32)20;
    while (j < (u32)23) {
        Res* w = new Res(j);
        j = j + (u32)1;
        if (j == (u32)22) break;
    }

    // nested: breaking the inner loop must release only the inner scope,
    // and the outer body local must still be released per iteration.
    Stdio.printf("-- nested\n");
    for (u32 a = (u32)30; a < (u32)32; a = a + (u32)1) {
        Res* outer = new Res(a);
        for (u32 b = (u32)40; b < (u32)43; b = b + (u32)1) {
            Res* inner = new Res(b);
            if (b == (u32)40) break;
        }
    }
    Stdio.printf("done\n");
}
