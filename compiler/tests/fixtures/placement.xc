// placement.xc — regression for the :banked / :shadow / :main
// function-placement annotations.
//
// On a banked target (xt / xe) the codegen normally puts every free
// function into the bank window at $4000-$7FFF; main itself, plus
// :irq and :vbi handlers, stay in main RAM. The placement
// annotations let the user override that:
//   :banked → bank window (explicit form of the current default)
//   :main   → opt out of banking, sit in main RAM at $A000+
//   :shadow → routed to a shadow-RAM segment (only on -shadow targets;
//             this fixture exercises just the parse / warn paths)
//
// On non-banked targets (xl) :banked is a no-op + warning. On
// non-shadow targets :shadow is a no-op + warning. This fixture is
// run on xl/xt/xe by the standard runner — the warnings fire on the
// targets that lack the resource but they don't cause a build error,
// and the runtime behaviour is identical because the routing falls
// through to default.

#import "Stdio.xc"

u8 testCount;
u8 failCount;
u8 fails[16];

void checkU8(u8 got, u8 want)
{
    testCount = testCount + 1;
    if (got != want) {
        if (failCount < 16) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

// Default placement — auto-banked on xt/xe, main on xl.
u8 dflt(u8 v) { return v + 1; }

// Explicit :banked — same effect as default on banked targets;
// no-op + warning on xl (where it falls through to main).
u8 banked(u8 v) :banked { return v + 2; }

// :main forces this out of the bank window on xt/xe so it lives in
// main RAM. On xl it's the implicit default.
u8 inMain(u8 v) :main { return v + 4; }

// :shadow asks for shadow-RAM placement. On the shadow targets in
// the runner today (none — xl/xt/xe only) this falls through to
// main and works identically. The annotation still parses; the
// warning is suppressed via XTWarnUnknownAnnotation if the user
// adds -Wno-unknown-annotation, but it shouldn't cause failures.
u8 shadowed(u8 v) :shadow { return v + 8; }

void main(void)
{
    testCount = 0;
    failCount = 0;

    // T1..T4 — each placement variant produces the right answer
    // regardless of where the codegen put it.
    checkU8(dflt(10),     11);   // 10 + 1
    checkU8(banked(10),   12);   // 10 + 2
    checkU8(inMain(10),   14);   // 10 + 4
    checkU8(shadowed(10), 18);   // 10 + 8

    // T5..T8 — chain calls so the bank-switch trampoline (or its
    // absence) gets exercised mid-flow rather than just once.
    u8 x;
    x = dflt(0);     checkU8(x, 1);
    x = banked(x);   checkU8(x, 3);
    x = inMain(x);   checkU8(x, 7);
    x = shadowed(x); checkU8(x, 15);

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}
