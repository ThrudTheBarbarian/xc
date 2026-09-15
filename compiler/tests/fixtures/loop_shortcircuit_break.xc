// loop_shortcircuit_break.xc — a `&&` loop condition with a `break` in the body.
//
// The IR verifier rejected this shape outright:
//
//   §12.4: phi in 'f/bb_1_exit' pair 0 refs 'bb_1_header' but pred 0 is
//          'bb_4_and_join'
//
// A short-circuit condition lowers into extra blocks, so the CondBranch that
// jumps to the loop exit is emitted in the LAST of them — not in the header.
// The exit-block phis named the header anyway, and the moment a `break` gave
// the exit a second predecessor (which is what forces a phi to exist at all),
// the mismatch surfaced. Any loop with `&&` or `||` in its condition AND a
// break in its body failed to compile at all; without the break there is no
// exit phi and the bug stayed invisible.
//
// Found by the self-hosted preprocessor (private:docs/Design/self-hosting.md M5) —
// `Preprocessor.parseCallArgs` scans `while (pos < len && depth > 0)` and
// breaks out on the closing paren. It is the first bug the self-hosting port
// found in the compiler, which is exactly the argument for doing the port.
//
//   T1  while + && + break
//   T2  while + || + break
//   T3  C-style for + && + break
//   T4  the same loops WITHOUT a break, so the non-phi path still works
//   T5  a value assigned only on the break path — the phi has to pick per edge

#import "Stdio.xc"
#import "Assert.xc"

u16 whileAndBreak(u16 n)
{
    u16 i = (u16)0;
    i16 d = (i16)1;
    while (i < n && d > (i16)0) {
        if (i == (u16)3) { i = i + (u16)1; break; }
        i = i + (u16)1;
    }
    return i;
}

u16 whileOrBreak(u16 n)
{
    u16 i = (u16)0;
    bool forced = false;
    while (i < n || forced) {
        if (i == (u16)2) { i = i + (u16)10; break; }
        i = i + (u16)1;
    }
    return i;
}

u16 forAndBreak(u16 n)
{
    u16 acc = (u16)0;
    for (u16 i = (u16)0; i < n && acc < (u16)100; i = i + (u16)1) {
        if (i == (u16)4) { acc = acc + (u16)1000; break; }
        acc = acc + i;
    }
    return acc;
}

u16 whileAndNoBreak(u16 n)
{
    u16 i = (u16)0;
    i16 d = (i16)1;
    while (i < n && d > (i16)0) i = i + (u16)1;
    return i;
}

// The interesting case for the exit phi: `tag` differs depending on WHICH edge
// reached the exit, so the exit really does need a phi with one operand per
// predecessor.
u16 taggedExit(u16 n)
{
    u16 i = (u16)0;
    u16 tag = (u16)7;
    while (i < n && i < (u16)100) {
        if (i == (u16)5) { tag = (u16)42; break; }
        i = i + (u16)1;
    }
    return tag;
}

void main(void)
{
    Assert.isEqual(whileAndBreak((u16)10), (u16)4);      // T1 — broke at i==3
    Assert.isEqual(whileAndBreak((u16)2),  (u16)2);      // …ran out first

    Assert.isEqual(whileOrBreak((u16)10), (u16)12);      // T2
    Assert.isEqual(whileOrBreak((u16)1),  (u16)1);

    Assert.isEqual(forAndBreak((u16)10), (u16)1006);     // T3 — 0+1+2+3 then +1000
    Assert.isEqual(forAndBreak((u16)3),  (u16)3);        // …no break: 0+1+2

    Assert.isEqual(whileAndNoBreak((u16)6), (u16)6);     // T4

    Assert.isEqual(taggedExit((u16)10), (u16)42);        // T5 — break edge
    Assert.isEqual(taggedExit((u16)3),  (u16)7);         // …condition edge

    Assert.summary();
    return;
}
