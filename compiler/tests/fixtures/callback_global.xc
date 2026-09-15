// callback_global.xc — a callback at FILE SCOPE: declared, assigned, and
// CALLED directly through the global.
//
// Reported from real code (2026-08-29). It failed differently in each
// compiler, which is why it needs a fixture rather than a one-line fix:
//
//   reference — "Expected 'identifier' but found ';'". The `callback` header
//     carries the declared name INSIDE itself, so by the time the top-level
//     declaration parser looked for a name it had already been consumed. The
//     local, ivar and parameter paths all read the stash; the top level was
//     the one place that did not.
//   shipped   — parsed and assigned fine, then gave up at the CALL:
//     `unsupported: bound call through gTap`. Its bound-call lowering handled
//     an SSA local and an ivar but not a global — the fallback the neighbouring
//     indirect-call path already had.
//
// Either compiler alone looked like one small bug. They were two.
#import "Stdio.xc"

callback gTap void(i32 n);           // file scope, no typedef

class Counter
{
    i32 total;
    void init(void)  { total = (i32)0; }
    void add(i32 n)  { total = total + n; }
}

i32 main(void)
{
    Counter* c = new Counter();

    // Empty until assigned, and testable as such.
    if (!gTap) { Stdio.printf("T1 empty\n"); }

    gTap = &c.add;
    if (gTap) { gTap((i32)7); }      // called through the GLOBAL, not a copy
    gTap((i32)5);
    Stdio.printf("T2 %d\n", c.total);

    // Still the same type as the sigil spelling, at file scope too.
    callback local void(i32 n);
    local = gTap;
    local((i32)3);
    Stdio.printf("T3 %d\n", c.total);
    return 0;
}
