//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// double_rand.xc — regression test for Math.rand() (double overload).
//
// The double rand() packs 48 random mantissa bits (from 3 xorshift
// steps) into an 8-byte double with sign=0, exp=-1, giving a value
// in [0.5, 1.0).
//
// Seeding the PRNG deterministically lets us byte-compare the output
// against the actual xorshift trace. Note the asm in random.asm
// treats `state<<7` as `(state.lo<<7)` — the high byte drops out of
// the shift entirely, so the trace differs from a textbook 16-bit
// xorshift. We just match what the runtime actually does:
//
//   seed = 0x0001
//   step 1 → state = 0x8181 → m0=$81, m1=$81
//   step 2 → state = 0xA061 → m2=$61, m3=$A0
//   step 3 → state = 0x39A9 → m4=$A9, m5=$39
//   result = {$00, $FF, $81, $81, $61, $A0, $A9, $39}

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

void main(void)
{
    testCount = 0;
    failCount = 0;

    // T1: seed=1 → deterministic mantissa trace above.
    {
        Math.setSeed(1);
        double v = Math.rand();
        asm { LDA v   : STA r0 : LDA v+1 : STA r1 : LDA v+2 : STA r2 : LDA v+3 : STA r3
              LDA v+4 : STA r4 : LDA v+5 : STA r5 : LDA v+6 : STA r6 : LDA v+7 : STA r7 }
        e0 = $00; e1 = $FF; e2 = $81; e3 = $81;
        e4 = $61; e5 = $A0; e6 = $A9; e7 = $39; record();
    }

    // T2: a second call with a known state should diverge from the
    //     first — guards against a regression where rand() ends up
    //     reusing the same step() state across calls.
    {
        Math.setSeed(1);
        double v1 = Math.rand();
        double v2 = Math.rand();
        // "Different" here = at least one of the 6 mantissa bytes
        // differs. Encode that as: r0 = 1 if different, else 0.
        u8 same; same = 1;
        asm {
            LDA v1+2 : CMP v2+2 : BNE _drand_diff
            LDA v1+3 : CMP v2+3 : BNE _drand_diff
            LDA v1+4 : CMP v2+4 : BNE _drand_diff
            LDA v1+5 : CMP v2+5 : BNE _drand_diff
            LDA v1+6 : CMP v2+6 : BNE _drand_diff
            LDA v1+7 : CMP v2+7 : BNE _drand_diff
            JMP _drand_end
        _drand_diff:
            LDA #$00
            STA same
        _drand_end:
        }
        r0 = 0; r1 = 0; r2 = 0; r3 = 0; r4 = 0; r5 = 0; r6 = 0; r7 = 0;
        if (same == 0) { r0 = 1; }
        e0 = 1; e1 = 0; e2 = 0; e3 = 0; e4 = 0; e5 = 0; e6 = 0; e7 = 0;
        record();
    }

    // T3: check the flags and exponent of a rand() output are always
    //     {$00, $FF} — that's the sole signature of the [0.5, 1.0)
    //     packing, independent of the mantissa.
    {
        Math.setSeed(42);
        double v = Math.rand();
        asm { LDA v   : STA r0 : LDA v+1 : STA r1 }
        r2 = 0; r3 = 0; r4 = 0; r5 = 0; r6 = 0; r7 = 0;
        e0 = $00; e1 = $FF;
        e2 = 0; e3 = 0; e4 = 0; e5 = 0; e6 = 0; e7 = 0;
        record();
    }

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}