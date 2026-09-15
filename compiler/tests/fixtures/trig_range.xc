//xtc-na: xt6502 — banked table-trig accuracy differs; arm64 uses native libm
// Regression for trig inputs outside [-π, π].
//
// Both fpTrig.asm (CORDIC, standard target) and fpTrigTab.asm
// (table, banked target) convert their input angle to a 16-bit
// Q3.13 fixed-point representation whose range is [-4, 4).
// Anything outside that overflowed the conversion silently —
// `sin(10.0)` came out as the wrong answer because the
// float-to-Q3.13 step truncated the high bits before any range
// reduction happened, and the existing _cordic_range_reduce
// only subtracts a single ±π once it's already in [-4, 4).
//
// The fix is a separate fpTrigReduce.asm runtime routine that
// fpSin/fpCos/fpTan call before the Q3.13 conversion when the
// input's exponent is ≥ 2 (magnitude ≥ 4). It uses fpMod by 2π
// followed by a conditional ±2π add to fold the angle into
// (-π, π], at which point the existing in-range path takes
// over.
//
// fpAtan covers the whole real line via the reciprocal fold and
// doesn't need this — the user's TODO note says so.
//
// NOTE: the banked target uses fpTrigTab.asm, whose in-range
// table interpolation is independently inaccurate (a lossy
// `idx ≈ angle_hi * 2` index calculation that was tracked
// against fairly loose tolerances). This regression sweep only
// covers the standard target; the banked target's table-based
// trig accuracy is a separate followup.

#import "Stdio.xc"
#import "Math.xc"

void main(void)
{
    float a;

    // sin(10) ≈ -0.5440
    a = Math.sin(10.0);
    if (a > -0.55 && a < -0.53) { Stdio.printf("T1 PASS\n"); }
    else                        { Stdio.printf("T1 FAIL\n"); }

    // cos(10) ≈ -0.8391
    a = Math.cos(10.0);
    if (a > -0.85 && a < -0.83) { Stdio.printf("T2 PASS\n"); }
    else                        { Stdio.printf("T2 FAIL\n"); }

    // sin(-10) ≈ 0.5440
    a = Math.sin(-10.0);
    if (a > 0.53 && a < 0.55)   { Stdio.printf("T3 PASS\n"); }
    else                        { Stdio.printf("T3 FAIL\n"); }

    // sin(100) ≈ -0.5063
    a = Math.sin(100.0);
    if (a > -0.52 && a < -0.49) { Stdio.printf("T4 PASS\n"); }
    else                        { Stdio.printf("T4 FAIL\n"); }

    // cos(100) ≈ 0.8623
    a = Math.cos(100.0);
    if (a > 0.85 && a < 0.87)   { Stdio.printf("T5 PASS\n"); }
    else                        { Stdio.printf("T5 FAIL\n"); }

    // tan(10) ≈ 0.6483
    a = Math.tan(10.0);
    if (a > 0.62 && a < 0.67)   { Stdio.printf("T6 PASS\n"); }
    else                        { Stdio.printf("T6 FAIL\n"); }

    // In-range cases stay correct:
    a = Math.sin(0.0);
    if (a < 0.001 && a > -0.001) { Stdio.printf("T7 PASS\n"); }
    else                         { Stdio.printf("T7 FAIL\n"); }

    a = Math.sin(1.0);
    if (a > 0.83 && a < 0.85)    { Stdio.printf("T8 PASS\n"); }
    else                         { Stdio.printf("T8 FAIL\n"); }

    a = Math.cos(1.0);
    if (a > 0.53 && a < 0.55)    { Stdio.printf("T9 PASS\n"); }
    else                         { Stdio.printf("T9 FAIL\n"); }
}
