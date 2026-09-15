// inliner_ordering.xc — regression for the -O2/-O3 leaf inliner's
// frame-save ordering bug.
//
// Prior behaviour: when a leaf function was inlined, the inliner
// stripped both the retaddr dance AND the param PLA pops out of the
// body and rewrote the caller's PHAs into direct STAs of the arg slot.
// That placed the arg-install STAs BEFORE the body's frame-save lines,
// so frame-save read the just-installed arg instead of the caller's
// pre-call ZP state — and on return the frame-restore wrote the arg
// value back into the caller's ZP slot, silently corrupting any
// caller local that happened to share the slot.
//
// Fixed by leaving the param PLAs inside the body and keeping the
// caller's PHAs live. Frame-save now runs first and captures the
// caller's real ZP state; the PLA pops the arg afterwards.
//
// This fixture calls small leaf helpers whose params and locals hit
// the same ZP slots main uses, so a regression immediately reappears
// as failing tests.

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

// Tiny leaf helpers the inliner is very likely to fold in at -O2+.
// Each takes a u8 param and declares a u8 local — exactly the shape
// that triggered the bug (param and local both land in low-ZP slots
// that overlap main's locals).
u8 dbl(u8 v)      { u8 r; r = v + v;     return r; }
u8 addOne(u8 v)   { u8 r; r = v + 1;     return r; }
u8 firstOfTwo(u8 a, u8 b) { u8 r; r = a; return r; }
u8 secondOfTwo(u8 a, u8 b) { u8 r; r = b; return r; }

// Back-to-back RMW on the same u8 local — used to collapse at -O2
// to a single `r = r + 2` because the dead-store-elim kill-chain
// didn't treat ADC as writing A. Any of the following helpers
// regress as soon as that bug returns.
u8 twoAdds(u8 v) {
    u8 r = 0;
    if (v == 1) { r = r + 1; r = r + 2; }
    return r;
}
u8 threeAdds(u8 v) {
    u8 r = 0;
    if (v == 1) { r = r + 1; r = r + 2; r = r + 4; }
    return r;
}

void main(void)
{
    testCount = 0;
    failCount = 0;

    // Four call sites each so the inliner's kMaxCallSites=4 cap still
    // lets it inline. Interleave helpers so main's ZP slots are
    // repeatedly rewritten, giving any broken frame-save plenty of
    // opportunity to clobber a caller local between tests.
    checkU8(dbl(3),   6);
    checkU8(dbl(5),   10);
    checkU8(dbl(64),  128);
    checkU8(dbl(127), 254);

    checkU8(addOne(0),   1);
    checkU8(addOne(99),  100);
    checkU8(addOne(254), 255);
    checkU8(addOne(7),   8);

    checkU8(firstOfTwo(10, 20),  10);
    checkU8(firstOfTwo(77, 88),  77);
    checkU8(secondOfTwo(10, 20), 20);
    checkU8(secondOfTwo(77, 88), 88);

    // Chain the helpers so the result of one feeds the next — this
    // pattern used to produce the worst corruption because the
    // returning frame-restore would overwrite main's working byte
    // with the last-installed arg value.
    u8 t;
    t = dbl(3);                  // 6
    t = addOne(t);               // 7
    t = dbl(t);                  // 14
    checkU8(t, 14);

    t = addOne(firstOfTwo(9, 1));    // 10
    checkU8(t, 10);

    t = dbl(secondOfTwo(2, 6));      // 12
    checkU8(t, 12);

    // Regression for the O2 RMW-fusion bug — twoAdds(1) should return
    // 3 (r + 1 = 1, then r + 2 = 3), not 2. Call 5 times (past the
    // inliner's kMaxCallSites=4 cap) so the dispatch is via a real
    // call — the ALU-op liveness fix applies independently of inlining.
    checkU8(twoAdds(1),   3);
    checkU8(twoAdds(2),   0);
    checkU8(twoAdds(1),   3);
    checkU8(twoAdds(1),   3);
    checkU8(twoAdds(1),   3);

    // Three back-to-back adds — guards against a partial fix that
    // only handles the first intermediate RMW.
    checkU8(threeAdds(1), 7);
    checkU8(threeAdds(2), 0);
    checkU8(threeAdds(1), 7);
    checkU8(threeAdds(1), 7);
    checkU8(threeAdds(1), 7);

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}
