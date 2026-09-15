// inline_method_value_args.xc — regression guard for the xt6502
// inline:/vtable value-returning method-call argument-width bug
// (private:docs/bugs/009). Found via gfx8_flood (Gfx.floodFill hung forever).
//
// A base-class method that drives an overridden, VALUE-RETURNING method
// through `inline:` (transitive self-dispatch) must widen each argument
// to the callee's parameter type before the dispatch. The xt6502 path
// pushed each arg at its own natural width, so a narrow arg (a u8 passed
// to an i16 parameter, or a small byte literal) was pushed one byte where
// the callee read two — shifting every later parameter and the frame, so
// the dispatched method read garbage and returned 0. floodFill's
// `inline:getPixel(cx, cy)` (cy a u8) then never saw a boundary pixel and
// flood-filled the whole screen forever.
//
// Values are deliberately distinctive (no $00 / $FF) so a no-op or
// misaligned call can't pass by coincidence.

#import "Stdio.xc"
#import "Assert.xc"

class Shape
{
    // Override point — base stub. Dispatched-to subclass returns a real
    // value computed from BOTH (wide) parameters.
    u8 score(i16 a, i16 b) { return 0; }

    // Base method that reaches the override via `inline:`. lo/hi are u8
    // and widen IMPLICITLY to score()'s i16 parameters — the exact shape
    // that misaligned the callee frame on xt6502. No explicit (i16) cast
    // here: an explicit cast pre-widens the arg and hides the bug; the
    // implicit widening is what the buggy lowering skipped.
    u8 combine(u8 lo, u8 hi)
    {
        return inline:score(lo, hi);
    }
}

class Box : Shape
{
    u8 score(i16 a, i16 b) { return (u8)(a + b); }
}

void main(void)
{
    Assert.reset();

    Box* s = new Box();

    // T1: value-returning inline call with widened args. $4A + $13 = $5D.
    Assert.isEqual((u16)s.combine($4A, $13), $5D);

    // T2: the floodFill shape — inline value used in a loop condition.
    // score(i, $20) must equal $20 + i for each i, so all five match.
    u8 hits = 0;
    u8 i = 0;
    while (i < 5)
    {
        if (s.combine(i, $20) == (u8)($20 + i)) { hits = hits + 1; }
        i = i + 1;
    }
    Assert.isEqual((u16)hits, 5);

    Stdio.printf("DONE 2\n");
    return;
}
