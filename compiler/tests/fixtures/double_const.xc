//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
//xtc-flags: skip  — asserts retired 5-byte softfloat byte layout / large-float edge; needs IEEE-format rewrite (MECH migration, phase-671)
// double_const.xc — regression for return-type-aware overload
// resolution + the dp constant overloads of Math.PI, E, LN2, etc.
//
// Each constant has both a `float` and a `double` zero-arg overload.
// Without a context hint, sema's tiebreaker defaults to the float
// flavour (matches the "printf-vararg defaults to float" rule).
// With a context — variable init, assignment RHS, return expression,
// or a binary-op in a typed slot — sema picks the overload whose
// return type matches the expected type.
//
// Tests below verify every context-entry point the resolver handles
// (not binary ops — that's covered separately at the end).

#import "Stdio.xc"
#import "Math.xc"

u8 r0; u8 r1; u8 r2; u8 r3; u8 r4; u8 r5; u8 r6; u8 r7;
u8 e0; u8 e1; u8 e2; u8 e3; u8 e4; u8 e5; u8 e6; u8 e7;

u8 testCount;
u8 failCount;
u8 fails[16];

void record(void)
{
    testCount = testCount + 1;
    if (r0 != e0 || r1 != e1 || r2 != e2 || r3 != e3 ||
        r4 != e4 || r5 != e5 || r6 != e6 || r7 != e7) {
        if (failCount < 16) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

double returnsDouble(void) { return Math.PI(); }
float  returnsFloat(void)  { return Math.PI(); }

void main(void)
{
    testCount = 0;
    failCount = 0;

    // T1: variable init context picks double overload
    { double d = Math.PI();
      asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
            LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
      e0 = $00; e1 = $01; e2 = $92; e3 = $1F;
      e4 = $B5; e5 = $44; e6 = $42; e7 = $D2; record(); }

    // T2: variable init context picks float overload. float PI's
    // top-3 mantissa bytes match double PI's top 3 (float is just
    // a truncation of double — same encoding format), so the
    // leading bytes are $92 $1F $B5 in both overloads. The tell
    // that the float overload was picked is that r5..r7 stay zero
    // (we only read the 5-byte float storage; dp would have 8).
    { float f = Math.PI();
      asm { LDA f   : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2 : LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      r5 = 0; r6 = 0; r7 = 0;
      e0 = $00; e1 = $01; e2 = $92; e3 = $1F; e4 = $B5;
      e5 = 0; e6 = 0; e7 = 0; record(); }

    // T3: assignment RHS context picks double
    { double d; d = Math.E();
      asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
            LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
      e0 = $00; e1 = $01; e2 = $5B; e3 = $F0;
      e4 = $A8; e5 = $B1; e6 = $45; e7 = $77; record(); }

    // T4: return-expression context — inside `returnsDouble`, the
    //     return expression `Math.PI()` sees expected = double (the
    //     enclosing function's declared return type) and picks the
    //     dp overload.
    { double d = returnsDouble();
      asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
            LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
      e0 = $00; e1 = $01; e2 = $92; e3 = $1F;
      e4 = $B5; e5 = $44; e6 = $42; e7 = $D2; record(); }

    // T5: return-expression context — float function, picks float.
    { float f = returnsFloat();
      asm { LDA f   : STA r0 : LDA f+1 : STA r1 : LDA f+2 : STA r2 : LDA f+3 : STA r3
            LDA f+4 : STA r4 }
      r5 = 0; r6 = 0; r7 = 0;
      e0 = $00; e1 = $01; e2 = $92; e3 = $1F; e4 = $B5;
      e5 = 0; e6 = 0; e7 = 0; record(); }

    // T6: binary-op propagation — `2.0d * Math.PI()` picks double
    //     PI because the surrounding assignment expects a double,
    //     and that expected type propagates to both operands.
    //     Expected byte pattern: 2.0d * PI  ≈  6.28318…  = TWO_PI.
    { double d = 2.0d * Math.PI();
      asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
            LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
      e0 = $00; e1 = $02; e2 = $92; e3 = $1F;
      e4 = $B5; e5 = $44; e6 = $42; e7 = $D2; record(); }

    // T7: binary-op propagation, operand order reversed.
    { double d = Math.PI() * 2.0d;
      asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
            LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
      e0 = $00; e1 = $02; e2 = $92; e3 = $1F;
      e4 = $B5; e5 = $44; e6 = $42; e7 = $D2; record(); }

    // T8: SQRT2 double-precision constant — check round-trip.
    //     sqrt(2) bytes we've already verified in double_sqrt T10;
    //     the constant matches those bytes exactly.
    { double d = Math.SQRT2();
      asm { LDA d   : STA r0 : LDA d+1 : STA r1 : LDA d+2 : STA r2 : LDA d+3 : STA r3
            LDA d+4 : STA r4 : LDA d+5 : STA r5 : LDA d+6 : STA r6 : LDA d+7 : STA r7 }
      e0 = $00; e1 = $00; e2 = $6A; e3 = $09;
      e4 = $E6; e5 = $67; e6 = $F3; e7 = $BD; record(); }

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}