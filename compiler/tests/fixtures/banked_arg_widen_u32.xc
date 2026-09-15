// banked_arg_widen_u32.xc — implicit narrow→u32 / narrow→i32
// widening at call sites.
//
// Sema accepts these conversions without injecting a cast node, so
// the codegen receives a u8/u16/i8/i16-typed expression in a 4-byte
// param slot and is responsible for synthesising the missing high
// bytes. Three latent bugs converged here:
//   1. The banked-call arg-emit fallback only stored 1-2 bytes,
//      leaving slot bytes 2-3 stale.
//   2. The standard codegen's emitWide4ArgPush returned NO for
//      non-width-4 args, so the scalar fallback pushed 1-2 bytes
//      and the callee popped stack garbage for the high half.
//   3. The identifier fast path on both codegens read 4 bytes from
//      a narrow global's address, picking up neighbour symbols.
//   4. emitWideStoreExtensionForRHS clobbered X with LDX #$00 when
//      X already held byte 1 of a width-2 RHS being widened to 4.
// Fixed by routing every paramWidth==4 narrow case through
// emitWideStoreExtensionForRHS (post-fix to the helper itself for
// the rhsWidth==2 → width==4 path).

#import "Stdio.xc"

u32 takesU32(u32 x) :banked
{
    return x;
}

i32 takesI32(i32 x) :banked
{
    return x;
}

u8 a8;
u8 b8;
u16 a16;
u16 b16;
i8 ai8;
i8 bi8;
i16 ai16;
i16 bi16;

void main(void)
{
    // Pre-load with a 4-byte literal so any leaked u32 high half is
    // visibly non-zero in the failure modes below.
    u32 prior = takesU32($DEADBEEF);
    if (prior == $DEADBEEF) { Stdio.printf("T0 PASS\n"); }
    else                    { Stdio.printf("T0 FAIL prior=%lx\n", prior); }

    // T1: u8+u8 expression → u32 param (argWidth=1 or 2 depending
    // on operator widening; either way < 4).
    a8 = 100;
    b8 = 50;
    u32 r1 = takesU32(a8 + b8);
    if (r1 == 150) { Stdio.printf("T1 PASS\n"); }
    else           { Stdio.printf("T1 FAIL r1=%lx\n", r1); }

    // T2: u16+u16 expression → u32 param (argWidth=2). Exercises
    // the helper's preserve-X path for rhsWidth==2 → width==4.
    a16 = 30000;
    b16 = 5000;
    u32 r2 = takesU32(a16 + b16);
    if (r2 == 35000) { Stdio.printf("T2 PASS\n"); }
    else             { Stdio.printf("T2 FAIL r2=%lx\n", r2); }

    // T3: bare u8 identifier → u32 param. Exercises the identifier
    // gate — narrow ident must fall through to widening, not read
    // 4 bytes from the global's address.
    a8 = 77;
    u32 r3 = takesU32(a8);
    if (r3 == 77) { Stdio.printf("T3 PASS\n"); }
    else          { Stdio.printf("T3 FAIL r3=%lx\n", r3); }

    // T4: bare u16 identifier → u32 param. Same gate, two-byte ident.
    a16 = 12345;
    u32 r4 = takesU32(a16);
    if (r4 == 12345) { Stdio.printf("T4 PASS\n"); }
    else             { Stdio.printf("T4 FAIL r4=%lx\n", r4); }

    // T5: i8+i8 negative result → i32 param. Sign-extend path.
    ai8 = -10;
    bi8 = -20;
    i32 r5 = takesI32(ai8 + bi8);
    if (r5 == -30) { Stdio.printf("T5 PASS\n"); }
    else           { Stdio.printf("T5 FAIL r5=%ld\n", r5); }

    // T6: i16+i16 negative → i32. Exercises the rhsWidth==2 signed
    // path in emitWideStoreExtensionForRHS (preserves A/X, derives
    // sign fill from X without clobbering it).
    ai16 = -20000;
    bi16 = -10000;
    i32 r6 = takesI32(ai16 + bi16);
    if (r6 == -30000) { Stdio.printf("T6 PASS\n"); }
    else              { Stdio.printf("T6 FAIL r6=%ld\n", r6); }

    // T7: bare i8 identifier (negative) → i32 param.
    ai8 = -42;
    i32 r7 = takesI32(ai8);
    if (r7 == -42) { Stdio.printf("T7 PASS\n"); }
    else           { Stdio.printf("T7 FAIL r7=%ld\n", r7); }

    // T8: bare i16 identifier (negative) → i32 param.
    ai16 = -12345;
    i32 r8 = takesI32(ai16);
    if (r8 == -12345) { Stdio.printf("T8 PASS\n"); }
    else              { Stdio.printf("T8 FAIL r8=%ld\n", r8); }

    Stdio.printf("DONE 8\n");
}
