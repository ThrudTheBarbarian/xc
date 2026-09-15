// Math.rand() bounded + range overloads — returns values in a caller-
// specified window instead of the full u8/u16 range. Each test draws
// many samples and asserts every draw lands in the expected window;
// if the PRNG or the modulo/range arithmetic is wrong the fixture
// emits FAIL before the PASS lines and the harness catches it.

#import "Stdio.xc"
#import "Math.xc"

void main(void)
    {
    Math.setSeed(12345);

    // T1: u8 bounded — Math.rand(9) must return a value in [0, 9].
    for (u8 i = 0; i < 40; i++)
        {
        u8 v = Math.rand(9);
        if (v > 9) { Stdio.printf("FAIL bounded u8 got=%u\n", (u16)v); return; }
        }
    Stdio.printf("T1 PASS\n");

    // T2: u8 range — Math.rand(100, 110) must return a value in [100, 110].
    for (u8 i = 0; i < 40; i++)
        {
        u8 v = Math.rand(100, 110);
        if (v < 100 || v > 110)
            {
            Stdio.printf("FAIL range u8 got=%u\n", (u16)v);
            return;
            }
        }
    Stdio.printf("T2 PASS\n");

    // T3: u16 bounded — Math.rand(1000) must return a value in [0, 1000].
    for (u8 i = 0; i < 40; i++)
        {
        u16 v = Math.rand(1000);
        if (v > 1000) { Stdio.printf("FAIL bounded u16 got=%u\n", v); return; }
        }
    Stdio.printf("T3 PASS\n");

    // T4: u16 range — Math.rand(5000, 5100) must return a value in [5000, 5100].
    for (u8 i = 0; i < 40; i++)
        {
        u16 v = Math.rand(5000, 5100);
        if (v < 5000 || v > 5100)
            {
            Stdio.printf("FAIL range u16 got=%u\n", v);
            return;
            }
        }
    Stdio.printf("T4 PASS\n");

    // T5: degenerate — rand(0) must always return 0.
    for (u8 i = 0; i < 10; i++)
        {
        u8 v = Math.rand((u8)0);
        if (v != 0) { Stdio.printf("FAIL rand(0) got=%u\n", (u16)v); return; }
        }
    Stdio.printf("T5 PASS\n");

    // T6: degenerate — rand(x, x) must always return x.
    for (u8 i = 0; i < 10; i++)
        {
        u16 v = Math.rand(42, 42);
        if (v != 42) { Stdio.printf("FAIL rand(42,42) got=%u\n", v); return; }
        }
    Stdio.printf("T6 PASS\n");

    // T7: boundary — Math.rand($FF) with a u8 must accept the full-range
    // case without tripping the mod-0 guard.
    for (u8 i = 0; i < 10; i++)
        {
        u8 v = Math.rand((u8)$FF);
        // No upper-bound check possible — every u8 is valid — but the
        // call must not crash or run the degenerate mod-0 path.
        (void)v;
        }
    Stdio.printf("T7 PASS\n");

    // T8: the existing nullary overloads still resolve and return a
    // distinct value each draw — regression guard in case the new
    // signatures shadowed them.
    u8 a = Math.rand();
    u8 b = Math.rand();
    u8 c = Math.rand();
    // Three draws from a 16-bit xorshift are extremely unlikely to
    // coincide — treat all-three-equal as a regression.
    if (a == b && b == c)
        { Stdio.printf("FAIL nullary u8 stuck a=%u\n", (u16)a); return; }
    Stdio.printf("T8 PASS\n");
    }
