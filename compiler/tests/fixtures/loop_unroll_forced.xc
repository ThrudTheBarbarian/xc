#use Stdio

// bug 211(b): `: unroll` must actually drive the IR loop unroller.
//
// It was parsed and INERT in both compilers — forceUnroll appeared six times
// in the whole reference tree, all parse-or-declare, never read — because it
// was wired to the AST optimiser that phase-323 removed, and nobody
// reconnected it to the IR unroller that replaced it. The IR carried no
// per-loop metadata, so there was nothing obvious to reconnect it to.
//
// THE TRIP COUNT IS LOAD-BEARING. Every target's default unrollMaxTrip is
// below 40 (arm64 32, m68k and arm9 16, wasm32 8, the base profile 4) and the
// forced cap is 64, so a 40-trip loop is unrolled ONLY when annotated. A
// 12-trip loop would be unrolled on arm64 either way and would prove nothing —
// a fixture that passes whether or not the feature works is worse than none.
//
// loop_unroll_annotation.xc covers the SYNTAX; this one covers the EFFECT.
// The value is checked as well as the shape: an unroller that drops or
// duplicates an iteration still has to produce 780.
i32 main()
{
    u16 t = (u16)0;
    for (u16 i = (u16)0; i < (u16)40; i = i + (u16)1) : unroll {
        t = t + i;
    }
    printf("%d\n", t);

    // The same loop WITHOUT the annotation, so the fixture pins that the
    // budget still applies where it was not asked for.
    u16 u = (u16)0;
    for (u16 i = (u16)0; i < (u16)40; i = i + (u16)1) {
        u = u + i;
    }
    printf("%d\n", u);
    return 0;
}
