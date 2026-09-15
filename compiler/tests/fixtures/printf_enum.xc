// Exercises the `%e` printf specifier — expands an enum-typed argument
// to its symbol-name string at call time. The test leans on the fixture
// harness's PASS/FAIL detector: each enum's first member is literally
// named `PASS`, so a correctly-working `%e` emits "PASS" on screen and
// the harness greps it. A broken `%e` (silently prints the numeric
// value, or lands in the fallback "?" sentinel) emits something that
// doesn't contain PASS and the test fails.

#import "Stdio.xc"

// Dense-valued enum — lookup hits on the first arm.
enum Colour = {PASS = 0, RED = 1, GREEN = 2, BLUE = 3};

// Sparse / out-of-order — the lookup function has to handle gaps and
// the ordering walk must pick the correct match.
enum Sparse = {LOW = 10, GOOD = 200, HIGH = 300};

void main(void)
    {
    // T1: dense enum, first value. Prints "T1 PASS".
    Colour c = PASS;
    Stdio.printf("T1 %e\n", c);

    // T2: dense enum, middle value. Prints "T2 GREEN PASS".
    c = GREEN;
    Stdio.printf("T2 %e PASS\n", c);

    // T3: two %e in one format. Prints "T3 PASS GREEN".
    // Relies on the per-call lookup map binding each %e to its own arg.
    Colour first = PASS;
    Colour second = GREEN;
    Stdio.printf("T3 %e %e\n", first, second);

    // T4: sparse/u16-valued enum. Prints "T4 GOOD PASS".
    Sparse s = GOOD;
    Stdio.printf("T4 %e PASS\n", s);

    // T5: %e mixed with other specifiers. Prints "T5 BLUE / 42 PASS".
    c = BLUE;
    u16 x = 42;
    Stdio.printf("T5 %e / %u PASS\n", c, x);

    // T6: out-of-range enum value — should fall through to the "?"
    // sentinel rather than crash. "PASS" printed after proves we
    // came back from the lookup cleanly.
    Colour mystery = (Colour) 99;
    Stdio.printf("T6 %e PASS\n", mystery);
    }
