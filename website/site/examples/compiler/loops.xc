// loops.xc — every loop form the language has, in one runnable program.
//
// Note there is no do/while: the loop forms are `while`, C-style `for`,
// and `for ... in` over an array.
#import "Foundation.xc"
#import "Stdio.xc"

i32 main(void)
{
    // 1. C-style for: init; condition; step.
    Stdio.print("for       ");
    for (u16 i = (u16)0; i < (u16)5; i = i + (u16)1)
        Stdio.printf("%d ", i);
    Stdio.print("\n");

    // 2. while — the test runs first, so the body may not run at all.
    Stdio.print("while     ");
    u16 n = (u16)5;
    while (n > (u16)0) { Stdio.printf("%d ", n); n = n - (u16)1; }
    Stdio.print("\n");

    // 3. for ... in, over an array. The loop variable takes the ELEMENT type,
    //    and the type may be omitted — it is inferred from the collection.
    u16 squares[5];
    for (u16 i = (u16)0; i < (u16)5; i = i + (u16)1)
        squares[i] = i * i;
    Stdio.print("for-in    ");
    for (u16 v in squares)
        Stdio.printf("%d ", v);
    Stdio.print("\n");

    Stdio.print("inferred  ");
    for (v in squares)                      // same loop, type inferred
        Stdio.printf("%d ", v);
    Stdio.print("\n");

    // 4. break and continue, as in C: continue skips to the step, break
    //    leaves the loop.
    Stdio.print("evens<=6  ");
    for (u16 i = (u16)0; i < (u16)10; i = i + (u16)1) {
        if ((i & (u16)1) != (u16)0) continue;
        if (i > (u16)6) break;
        Stdio.printf("%d ", i);
    }
    Stdio.print("\n");

    // 5. Nested: break leaves only the INNERMOST loop.
    Stdio.print("nested    ");
    for (u16 r = (u16)0; r < (u16)3; r = r + (u16)1)
        for (u16 c = (u16)0; c < (u16)3; c = c + (u16)1) {
            if (c == (u16)2) break;
            Stdio.printf("%d%d ", r, c);
        }
    Stdio.print("\n");

    // 6. `: unroll` asks the optimiser to unroll a counted loop fully.
    //    Purely a performance annotation — the result is identical.
    Stdio.print("unrolled  ");
    for (u16 i = (u16)0; i < (u16)4; i = i + (u16)1) : unroll
        Stdio.printf("%d ", i);
    Stdio.print("\n");
    return 0;
}
