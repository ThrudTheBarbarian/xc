// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// Math.xc — random number generation and math functions for xtc
// =============================================================
//
// Usage (static — no instance needed):
//   Math.setSeed(0);               // seed from hardware entropy
//   u8  r8  = Math.rand();        // 0..255
//   u16 r16 = Math.rand();        // 0..65535
//   u32 r32 = Math.rand();        // 0..$FFFFFFFF
//   float rf = Math.rand();       // 0.5 .. ~1.0
//   u8  r   = Math.rand(9);       // 0..9 inclusive
//   u8  r   = Math.rand(100, 110);// 100..110 inclusive (u8)
//   u16 r   = Math.rand(1000);    // 0..1000 inclusive (u16)
//   u16 r   = Math.rand(5000, 5100); // 5000..5100 inclusive (u16)
//   float sq = Math.sqrt(2.0);    // square root
//   float s  = Math.sin(1.57);   // trig (radians)
//   float c  = Math.cos(0.0);
//   float t  = Math.tan(0.785);
//   float a  = Math.atan(1.0);
//
// Trig functions use CORDIC in standard mode (compact, no tables)
// and lookup tables in banked mode (faster, table in code segment).
//
// The PRNG uses a 16-bit xorshift algorithm (Marsaglia, shifts 7,9,8)
// with a period of 65535. State is stored in the class's inline data
// block (__sdata_Math), consuming 0 ZP bytes.
//
// Init is called automatically on first use, seeding from the Atari
// RANDOM register ($D20A). Call setSeed() to override.
//
// The float and double rand() overloads return values in the range
// [0.5, 1.0) — this is the natural output of a random mantissa with
// exponent -1 in the 5- / 8-byte float format ((1 + m/2^N) * 2^-1).
//
// ── ENABLE_DOUBLE ───────────────────────────────────────────────────
// Gate for the double overloads that require heavier-weight runtime
// (e.g. `pow(double, i16)` pulls `dpMul` into the main region).
// Reachability analysis now trims unused methods before they hit
// the binary, so simply importing Math.xc no longer bloats fp-only
// programs — that used to be the reason for this gate. It stays in
// place as an escape hatch: user can force-enable with
// `-DENABLE_DOUBLE=1` or force-disable with `-DENABLE_DOUBLE=0`,
// and the default tracks memory-model headroom.
#ifndef ENABLE_DOUBLE
#define ENABLE_DOUBLE 1
#endif

class Math
    {
    u8 seedLo;
    u8 seedHi;

    void init(void)
        {
        // Default seed from the hardware RANDOM register. The asm must write
        // LOCALS, not the static ivars directly: a bare `STA seedLo` in an asm
        // block is an undefined symbol to the assembler (it resolves to $0000,
        // corrupting zero page and never seeding the PRNG) — the ivar store has
        // to go through xtc code, exactly as setSeed() below does. (bug 150)
        u8 lo;
        u8 hi;
        asm
        {
            LDA $D20A
            STA lo
            LDA $D20A
            STA hi
        }
        // Guard against zero seed
        if (lo == 0) if (hi == 0)
            lo = 1;
        seedLo = lo;
        seedHi = hi;
        }

    // ── Seed the PRNG ────────────────────────────────────────────────
    // If seed == 0, read RANDOM ($D20A) twice for hardware entropy.

    static void setSeed(u16 seed)
        {
        u8 lo;
        u8 hi;
        asm
        {
            LDA seed
            STA lo
            LDA seed+1
            STA hi
        }

        if (lo == 0) if (hi == 0)
            {
            asm
            {
                    LDA $D20A
                    STA lo
                    LDA $D20A
                    STA hi
            }
            if (lo == 0) if (hi == 0)
                lo = 1;
            }

        seedLo = lo;
        seedHi = hi;
        }

    // ── Core xorshift step ───────────────────────────────────────────
    // Advances the 16-bit state in seedLo/seedHi.
    // Marsaglia xorshift triple (7, 9, 8):
    //   state ^= state << 7
    //   state ^= state >> 9
    //   state ^= state << 8

    static void step(void)
        {
        asm
        {
            // state ^= state << 7
            // (state<<7) = (state<<8)>>1
            LDA seedLo
            LSR A
            STA $86
            LDA #$00
            ROR A
            EOR seedLo
            STA seedLo
            LDA $86
            EOR seedHi
            STA seedHi

                                                // state ^= state >> 9
                                                // (state>>9) = {0, hi>>1}
            LDA seedHi
            LSR A
            EOR seedLo
            STA seedLo

                                                                // state ^= state << 8
                                                                // (state<<8) = {lo, 0}; only hi changes
            LDA seedLo
            EOR seedHi
            STA seedHi
        }
        }

    // ── rand (u8): random 0..255 ─────────────────────────────────────

    static u8 rand(void)
        {
        step();
        u8 result;
        asm
        {
            LDA seedLo
            STA result
        }
        return result;
        }

    // ── rand (u16): random 0..65535 ──────────────────────────────────

    static u16 rand(void)
        {
        step();
        u16 result;
        asm
            {
            LDA seedLo
            STA result
            LDA seedHi
            STA result+1
            }
        return result;
        }

    // ── rand (u8, bounded): random 0..max inclusive ──────────────────
    // `Math.rand(n)` returns a value in [0, n]. The natural expression
    // `rand() % (n + 1)` works for every n except $FF, where `n + 1`
    // overflows to 0 and the modulo is undefined — the $FF special-
    // case returns the raw random byte (which is already [0, $FF]).
    // The raw byte is pulled by stepping the PRNG and reading seedLo
    // inline; using `rand()` from here would force the overload
    // resolver to pick among the nullary overloads without enough
    // context and it picks the wrong one.

    static u8 rand(u8 max)
        {
        step();
        u8 r;
        asm { LDA seedLo : STA r }
        if (max == $FF)
            {
            return r;
            }
        return r % (max + 1);
        }

    // ── rand (u8, range): random lo..hi inclusive ────────────────────
    // `Math.rand(a, b)` returns a value in [a, b]. Caller is expected
    // to pass `a <= b` — if not, `hi - lo` underflows as a u8 and the
    // result is nonsense (not a crash), matching how xtc treats other
    // signed/unsigned argument misuse.

    static u8 rand(u8 lo, u8 hi)
        {
        return lo + rand(hi - lo);
        }

    // ── rand (u16, bounded): random 0..max inclusive ─────────────────
    // Same shape as the u8 bounded variant, widened to u16. $FFFF is
    // the special-case that would overflow `max + 1`.

    static u16 rand(u16 max)
        {
        step();
        u16 r;
        asm
            {
            LDA seedLo : STA r
            LDA seedHi : STA r+1
            }
        if (max == $FFFF)
            {
            return r;
            }
        return r % (max + 1);
        }

    // ── rand (u16, range): random lo..hi inclusive ───────────────────

    static u16 rand(u16 lo, u16 hi)
        {
        return lo + rand(hi - lo);
        }

    // ── rand (u32): random 0..$FFFFFFFF ──────────────────────────────
    // Calls step() twice to fill all 4 bytes.

    static u32 rand(void)
        {
        u32 result;
        step();
        asm
            {
            LDA seedLo
            STA result
            LDA seedHi
            STA result+1
            }
        step();
        asm
            {
            LDA seedLo
            STA result+2
            LDA seedHi
            STA result+3
            }
        return result;
        }

    // ── rand (float): random float [0.5, 1.0) ────────────────────────
    // Generates a 24-bit random mantissa via two xorshift steps, then
    // packs it into a 5-byte float with exponent -1.
    // Result = (1 + mantissa/2^24) * 2^-1, giving [0.5, ~1.0).

    static float rand(void)
        {
        step();
        u8 m0;
        u8 m1;
        asm
            {
            LDA seedLo : STA m0
            LDA seedHi : STA m1
            }
        step();
        u8 m2;
        asm { LDA seedLo : STA m2 }

        // Pack into 5-byte float: sign=0, exponent=-1 ($FF),
        // mantissa = 3 random bytes (MSByte first).
        float result = {$00, $FF, m0, m1, m2};
        return result;
        }

#if ENABLE_DOUBLE
    // ── rand (double): random double [0.5, 1.0) ──────────────────────
    // Widened sibling of the float rand(): generates a 48-bit random
    // mantissa via three xorshift steps (each step returns 16 bits),
    // then packs it into an 8-byte double with exponent -1.
    // Result = (1 + mantissa/2^48) * 2^-1, giving [0.5, ~1.0).

    static double rand(void)
        {
        step();
        u8 m0;
        u8 m1;
        asm
            {
            LDA seedLo : STA m0
            LDA seedHi : STA m1
            }
        step();
        u8 m2;
        u8 m3;
        asm
            {
            LDA seedLo : STA m2
            LDA seedHi : STA m3
            }
        step();
        u8 m4;
        u8 m5;
        asm
        {
            LDA seedLo : STA m4
            LDA seedHi : STA m5
        }

        // Pack into 8-byte double: sign=0, exponent=-1 ($FF),
        // mantissa = 6 random bytes (MSByte first).
        double result = {$00, $FF, m0, m1, m2, m3, m4, m5};
        return result;
        }
#endif // ENABLE_DOUBLE — rand(double)

    // ── sqrt via Newton–Raphson in IEEE float (arithmetic on MECH) ────
    // x <- 0.5(x + val/x). Quadratic convergence; a fixed iteration count
    // covers the double's range. Replaces the 5-byte softfloat dpSqrt.
    static double sqrt(double val)
        {
        double x;
        u8 i;
        if (val <= 0.0d)
            {
            return 0.0d;
            }
        x = val;
        // stable starting point < 1
        if (x < 1.0d)
            {
            x = 1.0d;
            }
        i = 0;
        while (i < 40)
            {
            x = 0.5d * (x + val / x);
            i = i + 1;
            }
        return x;
        }

    static float sqrt(float val)
        {
        return (float)sqrt((double)val);
        }

    // ── abs: absolute value, overloaded by argument type ─────────────
    // Float overload just clears the sign bit (bit 0 of byte 0).
    // Integer overloads check the sign bit / sign byte and twos-
    // complement-negate when negative. The 8/16/32-bit signed
    // versions all share the `abs` name via parameter-type overload
    // resolution; unsigned types don't need an abs at all (they're
    // non-negative by construction).

    // abs via compare + negate — format-agnostic (MECH FCmp/FNeg), so it is
    // correct for IEEE without touching sign-bit layout.
    static float abs(float val)
        {
        if (val < 0.0)
            {
            return 0.0 - val;
            }
        return val;
        }

    static i8 abs(i8 val)
        {
        i8 result;
        asm
        {
            LDA val
            BPL .i8abs_pos
            EOR #$FF
            CLC
            ADC #$01
        .i8abs_pos:
            STA result
        }
        return result;
        }

    static i16 abs(i16 val)
        {
        i16 result;
        asm
        {
            LDA val+1
            BPL .i16abs_pos
            ; Negative: two's-complement negate the 16-bit value.
            SEC
            LDA #$00
            SBC val
            STA result
            LDA #$00
            SBC val+1
            STA result+1
            JMP .i16abs_done
        .i16abs_pos:
            LDA val
            STA result
            LDA val+1
            STA result+1
        .i16abs_done:
        }
        return result;
        }

    static i32 abs(i32 val)
        {
        i32 result;
        asm
        {
            LDA val+3
            BPL .i32abs_pos
            ; Negative: two's-complement negate the 32-bit value.
            SEC
            LDA #$00
            SBC val
            STA result
            LDA #$00
            SBC val+1
            STA result+1
            LDA #$00
            SBC val+2
            STA result+2
            LDA #$00
            SBC val+3
            STA result+3
            JMP .i32abs_done
        .i32abs_pos:
            LDA val
            STA result
            LDA val+1
            STA result+1
            LDA val+2
            STA result+2
            LDA val+3
            STA result+3
        .i32abs_done:
        }
        return result;
        }

    // ── ln / exp / pow ───────────────────────────────────────────────
    // Natural logarithm, natural exponential, and power function.
    // Implemented in xtc using Horner-form polynomial approximations
    // rather than hand-written asm — each routine runs through ~10-15
    // calls to the fp* runtime primitives, so per-call cost is high
    // (~150-300 K cycles for pow) but correctness is clear and the
    // source is maintainable. If these turn out to be hot paths, the
    // inner loop is a natural candidate to lift into raw asm later.

    // ── ln: natural logarithm ────────────────────────────────────────
    //
    // For val > 0, write val = m * 2^k with m taken from the IEEE
    // mantissa and k from the biased exponent field. Then:
    //
    //    ln(val) = ln(m) + k * ln(2)
    //
    // m starts in [1, 2) and is halved (k + 1) when above sqrt(2), so
    // m ∈ [sqrt(2)/2, sqrt(2)). Substitute u = (m - 1) / (m + 1), which
    // puts |u| below 0.172. Then:
    //
    //    ln(m) = 2 * atanh(u)
    //          = 2 * (u + u^3/3 + u^5/5 + u^7/7 + ...)
    //
    // Six terms leave the first omitted one near 2^-30 of the result,
    // below float precision. Evaluated via Horner on u^2.
    //
    // binary32 is little-endian: byte 3 holds the sign and exponent
    // bits 7..1, bit 7 of byte 2 holds exponent bit 0. A subnormal
    // input is scaled by 2^24 first so its exponent field is nonzero.
    //
    // Special cases:
    //   val = 0     → returns 0 (a tame sentinel rather than -inf).
    //   val < 0     → returns 0 (ditto; real ln(negative) would be a
    //                 complex number).
    //   +inf / NaN  → returned unchanged.
    //   val = 1     → m = 1, u = 0, k = 0, returns exact 0.

    static float ln(float val)
        {
        if (val == 0.0)
            return 0.0;
        if (val < 0.0)
            return 0.0;

        i16 k = 0;
        u8 hi;
        u8 lo;
        asm
        {
            LDA val+3
            STA hi
            LDA val+2
            STA lo
        }
        if (hi == 0 && (lo & $80) == 0)
            {
            val = val * 16777216.0; // 2^24
            k = -24;
            asm
            {
                LDA val+3
                STA hi
                LDA val+2
                STA lo
            }
            }
        u16 e = ((u16)(hi & $7F) << 1) | (u16)(lo >> 7);
        if (e == $FF)
            return val;
        k = k + (i16)e - 127;

        // m = val with the exponent field set to the bias (127), so
        // m = 1.mantissa ∈ [1, 2).
        float m = val;
        asm
            {
            LDA #$3F : STA m+3
            LDA val+2 : ORA #$80 : STA m+2
            }
        if (m > 1.41421356)
            {
            m = m * 0.5;
            k = k + 1;
            }

        float u = (m - 1.0) / (m + 1.0);
        float u2 = u * u;

        // Horner form for atanh series truncated to 6 terms:
        //   atanh(u) = u * (1 + u2 * (1/3 + u2 * (1/5 + u2 * (1/7 +
        //              u2 * (1/9 + u2 * (1/11))))))
        float sum = 0.09090909;      // 1/11
        sum = 0.11111111 + u2 * sum; // 1/9
        sum = 0.14285714 + u2 * sum; // 1/7
        sum = 0.20000000 + u2 * sum; // 1/5
        sum = 0.33333333 + u2 * sum; // 1/3
        sum = 1.0 + u2 * sum;
        float lnm = 2.0 * u * sum;

        float kf = k;
        return lnm + kf * Math.LN2();
        }

    // ── exp: natural exponential ─────────────────────────────────────
    //
    // Range-reduce by repeated halving: divide x by 2 until |x| ≤ 1,
    // counting the halvings. Then evaluate the Taylor series for
    // exp(x) on the small reduced x, and square the result once per
    // halving to reconstruct the full value:
    //
    //    exp(x) = (exp(x/2^n))^(2^n)
    //
    // The Taylor series 1 + x + x^2/2! + x^3/3! + ... converges
    // rapidly for |x| ≤ 1 — ten terms give well below 24-bit
    // precision. Evaluated via Horner with pre-computed reciprocal
    // factorial constants.
    //
    // Special case: exp(0) = 1 comes out of the series directly.

    static float exp(float x)
        {
        // Halve until |x| ≤ 1, capped at a generous bound so a wild
        // input can't hang the loop.
        u8 halvings = 0;
        float ax = x;
        if (ax < 0.0)
            ax = 0.0 - ax;
        while (ax > 1.0)
            {
            x = x * 0.5;
            ax = ax * 0.5;
            halvings = halvings + 1;
            if (halvings >= 20)
                {
                break;
                }
            }

        // Horner form for Taylor series to 10 terms:
        //   exp(x) = 1 + x*(1 + x*(1/2 + x*(1/6 + x*(1/24 + x*(1/120 +
        //            x*(1/720 + x*(1/5040 + x*(1/40320 + x*(1/362880)))))))))
        float sum = 0.00000276;     // 1/362880
        sum = 0.00002480 + x * sum; // 1/40320
        sum = 0.00019841 + x * sum; // 1/5040
        sum = 0.00138889 + x * sum; // 1/720
        sum = 0.00833333 + x * sum; // 1/120
        sum = 0.04166667 + x * sum; // 1/24
        sum = 0.16666667 + x * sum; // 1/6
        sum = 0.50000000 + x * sum; // 1/2
        sum = 1.00000000 + x * sum; // 1/1
        sum = 1.00000000 + x * sum; // 1

        // Square `halvings` times to undo the halving.
        u8 i;
        for (i = 0; i < halvings; i = i + 1)
            {
            sum = sum * sum;
            }

        return sum;
        }

    // ── pow: general power function ──────────────────────────────────
    //
    // pow(val, power) = exp(power * ln(val)) for val > 0.
    //
    // Special cases:
    //   val = 0           → returns 0 (even for negative power, which
    //                       would be +inf mathematically).
    //   power = 0         → returns 1 (even for val = 0, matching the
    //                       C convention).
    //   val < 0           → returns 0 as a sentinel; a correct result
    //                       would need complex arithmetic for non-
    //                       integer powers, which we don't have.

    static float pow(float val, float power)
        {
        if (power == 0.0)
            return 1.0;
        if (val == 0.0)
            return 0.0;
        if (val < 0.0)
            return 0.0;
        return Math.exp(power * Math.ln(val));
        }

    // ── pow (integer exponent overload) ──────────────────────────────
    //
    // Binary exponentiation (square-and-multiply), O(log |power|) float
    // multiplies. Called automatically via parameter-type overload
    // resolution when the exponent is an integer type:
    //
    //     Math.pow(x, 3)     // i8/u8 literal → this overload
    //     Math.pow(x, 10)
    //     Math.pow(x, -5)    // negated i8 literal → this overload
    //     Math.pow(x, 3.5)   // float literal  → general pow(float, float)
    //
    // Cost comparison at `x^10`:
    //   general path (exp(10 * ln(x))):     ~300 K cycles
    //   binary exponentiation (this path):  ~60 K cycles    (5× faster)
    //
    // The gap widens with smaller integer exponents because the binary
    // path scales O(log |power|) while the general path is flat. For
    // |power| up to 127 the binary path beats the general path by a
    // factor of 2-5×, so the integer overload always wins when it's
    // eligible.
    //
    // Negative exponents invert the final result (1 / x^|power|).

    static float pow(float val, i16 power)
        {
        if (power == 0)
            return 1.0;
        if (val == 0.0)
            return 0.0;

        bool negative_power = false;
        if (power < 0)
            {
            negative_power = true;
            power = 0 - power;
            }

        // Binary exponentiation. The first non-trivial bit assigns
        // `result = base` directly rather than computing
        // `result = 1.0 * base`, which would be mathematically
        // equivalent but adds a real fpMul with its own ~1 ulp
        // rounding error. Previously pow(val, 2) went:
        //   result = 1.0 ; base = val*val ; result = 1.0 * base
        // which is two multiplies, one of them an identity. Over the
        // ~1000 squarings in an AHL-style benchmark the accumulated
        // rounding drift was exactly 2x the error of a direct a*a.
        // The `have_result` flag skips the identity mul and produces
        // bit-exact parity with a*a for power = 2, and drops one fpMul
        // per call for every other power as well.
        float result;
        bool have_result = false;
        float base = val;

        while (power > 0)
            {
            if ((power & 1) != 0)
                {
                if (have_result)
                    {
                    result = result * base;
                    }
                else
                    {
                    result = base;
                    have_result = true;
                    }
                }
            power = power >> 1;
            if (power > 0)
                {
                base = base * base;
                }
            }

        if (negative_power)
            {
            result = 1.0 / result;
            }
        return result;
        }

    // ── Trigonometric functions ───────────────────────────────────────
    // Angles are in radians. Uses CORDIC in standard mode, lookup
    // tables in banked mode (selected automatically by the compiler).

    // Float trig delegates to the double implementations (Horner series in
    // IEEE arithmetic on MECH) — the old fpSin/fpCos/fpTan softfloat routines
    // assumed the retired 5-byte format.
    static float sin(float angle)
        {
        return (float)sin((double)angle);
        }
    static float cos(float angle)
        {
        return (float)cos((double)angle);
        }
    static float tan(float angle)
        {
        return (float)tan((double)angle);
        }

    // ── Math constants ────────────────────────────────────────────────
    // xtc has no class-level constants, so each value is a zero-arg
    // static method returning a pre-encoded 5-byte float literal.
    // Usage: float x = Math.PI();

    static float E(void)
        {
        return 2.71828175;
        }
    static float LOG2E(void)
        {
        return 1.44269502;
        }
    static float LOG10E(void)
        {
        return 0.434294477;
        }
    static float LN2(void)
        {
        return 0.693147153;
        }
    static float LN10(void)
        {
        return 2.30258501;
        }
    static float PI(void)
        {
        return 3.14159262;
        }
    static float PI_2(void)
        {
        return 1.57079631;
        }
    static float PI_4(void)
        {
        return 0.785398155;
        }
    // 1/pi — identifier can't start with a digit, so renamed INV_PI.
    static float INV_PI(void)
        {
        return 0.318309873;
        }
    // 2/pi
    static float TWO_PI(void)
        {
        return 6.28318530717958647692;
        }
    // 2/sqrt(pi)
    static float TWO_SQRTPI(void)
        {
        return 1.12837917;
        }
    static float SQRT2(void)
        {
        return 1.41421354;
        }
    // 1/sqrt(2)
    static float SQRT1_2(void)
        {
        return 0.707106769;
        }

    static float atan(float x)
        {
        return (float)atan((double)x);
        }

    // ── Double overloads ─────────────────────────────────────────────
    // Parameter-type-overloaded `double` siblings of the float API.
    // Precision breakdown depends on ENABLE_DOUBLE (set at the top
    // of this file):
    //
    //   Always full dp precision (small routines, no heavy runtime):
    //     abs(double)         — inline sign-clear + byte copy, no
    //                           JSR. (There's no standalone dpAbs
    //                           routine — abs is width-agnostic and
    //                           fpAbs covers both widths if anything
    //                           ever needs to call through a label.)
    //     sqrt(double)        — real 49-iter dpSqrt (defined above)
    //
    //   When ENABLE_DOUBLE=1, full dp precision via Horner-Taylor
    //   bodies compiled into the banked code page:
    //     sin, cos, tan, atan, ln, exp,
    //     pow(double, i16), pow(double, double)
    //
    //   When ENABLE_DOUBLE=0, #warning + narrow-to-float stopgap.
    //   The stopgap form is:
    //     (double)-out ← sin((float)-in)
    //   Narrowing is free (dpToFp is an RTS — the top 5 bytes of
    //   a double are already a valid float encoding); widening
    //   just zeros the low 3 mantissa bytes. The fp algorithms
    //   give ~14 bits (trig) / ~18 bits (ln/exp) / ~24 bits
    //   (mul-only paths). Users who need full 48-bit precision
    //   must enable the real implementations.

#if ENABLE_DOUBLE
    static double abs(double val)
        {
        if (val < 0.0d)
            {
            return 0.0d - val;
            }
        return val;
        }

    // Full-precision 48-bit sin. Reduce angle to [-π/2, π/2] using
    // periodicity (mod 2π) and sin(π - x) = sin(x), then evaluate
    // a 12-term Taylor-Horner on x² (error below 2^-48 for
    // |x| ≤ π/2).
    static double sin(double angle)
        {
        if (angle == 0.0d)
            return 0.0d;

        double twoPi = Math.TWO_PI();
        double pi = Math.PI();
        double halfPi = Math.PI_2();

        // Reduce to (-π, π] by subtracting/adding 2π. Loop cap
        // prevents a runaway for nonsensical huge inputs; at 30
        // iterations we've reduced through |angle| ≤ 30 * 2π ≈ 188,
        // plenty for realistic user code.
        u8 cap = 0;
        while (angle > pi)
            {
            angle = angle - twoPi;
            cap = cap + 1;
            if (cap >= 30)
                {
                break;
                }
            }
        while (angle < 0.0d - pi)
            {
            angle = angle + twoPi;
            cap = cap + 1;
            if (cap >= 60)
                {
                break;
                }
            }

        // sin(π - x) = sin(x) handles (π/2, π]
        // sin(-π - x) = sin(-x) handles [-π, -π/2)  (equivalently: -π-x ↔ +π+x
        //   after negation, then sin(-y) = -sin(y) … simpler to just
        //   reflect via sin(x) = -sin(-π - x) for x < -π/2.)
        if (angle > halfPi)
            angle = pi - angle;
        if (angle < 0.0d - halfPi)
            angle = (0.0d - pi) - angle;

        // Taylor Horner on x² — 12 terms, innermost first.
        double x2 = angle * angle;
        double s = -3.86817017063068403771691193152281E-23d;   // -1/23!
        s = 1.95729410633912612308475743735054E-20d + x2 * s;  // +1/21!
        s = -8.22063524662432971695598123687228E-18d + x2 * s; // -1/19!
        s = 2.81145725434552076319894558301032E-15d + x2 * s;  // +1/17!
        s = -7.64716373181981647590113198578807E-13d + x2 * s; // -1/15!
        s = 1.60590438368216145993923771701549E-10d + x2 * s;  // +1/13!
        s = -0.0000000250521083854417187750521084d + x2 * s;   // -1/11!
        s = 0.0000027557319223985890652557319224d + x2 * s;    // +1/9!
        s = -0.0001984126984126984126984126984127d + x2 * s;   // -1/7!
        s = 0.0083333333333333333333333333333333d + x2 * s;    // +1/5!
        s = -0.1666666666666666666666666666666667d + x2 * s;   // -1/3!
        s = 1.0d + x2 * s;                                     // +1/1!

        return angle * s;
        }

    // Full-precision 48-bit cos. Same reduction as sin, then
    // cos(x) = 1 - x²/2! + x⁴/4! - x⁶/6! + ... (12 terms).
    static double cos(double angle)
        {
        double twoPi = Math.TWO_PI();
        double pi = Math.PI();
        double halfPi = Math.PI_2();

        // cos is even: absorb sign.
        if (angle < 0.0d)
            angle = 0.0d - angle;

        // Reduce to [0, 2π] then to [0, π] using cos(2π - x) = cos(x).
        u8 cap = 0;
        while (angle > twoPi)
            {
            angle = angle - twoPi;
            cap = cap + 1;
            if (cap >= 60)
                {
                break;
                }
            }
        if (angle > pi)
            angle = twoPi - angle;

        // Further reduce to [0, π/2] using cos(π - x) = -cos(x).
        // Remember the sign flip.
        bool negate = false;
        if (angle > halfPi)
            {
            angle = pi - angle;
            negate = true;
            }

        // Taylor Horner on x² — 12 terms.
        double x2 = angle * angle;
        double s = -8.89679139245057328674889744250247E-22d; // -1/22!
        s = 4.11031762331216485847799061843614E-19d + x2 * s;
        s = -1.56192069685862264622163643500573E-16d + x2 * s;
        s = 4.77947733238738529743820749111754E-14d + x2 * s;
        s = -1.14707455977297247138516979786821E-11d + x2 * s;
        s = 2.08767569878680989792100903212014E-9d + x2 * s;
        s = -0.0000002755731922398589065255731922d + x2 * s;
        s = 0.0000248015873015873015873015873016d + x2 * s;
        s = -0.0013888888888888888888888888888889d + x2 * s;
        s = 0.0416666666666666666666666666666667d + x2 * s;
        s = -0.5d + x2 * s;
        s = 1.0d + x2 * s;

        if (negate)
            s = 0.0d - s;
        return s;
        }

    // tan(x) = sin(x) / cos(x). Inherits real dp precision from
    // the two underlying calls; near the asymptotes (odd multiples
    // of π/2) the division amplifies error catastrophically,
    // matching the fp behaviour.
    static double tan(double angle)
        {
        return Math.sin(angle) / Math.cos(angle);
        }

    // Full-precision 48-bit atan. Naive Taylor converges only
    // as 1/(2k+1), so it's unusable over |x| close to 1 without
    // argument reduction. Two folds tighten the range:
    //
    //   1. Reciprocal:  atan(x) = π/2 - atan(1/x)  for x > 1.
    //                   Puts x ∈ (0, 1].
    //   2. Shift:       atan(x) = π/4 + atan((x-1)/(x+1))
    //                   for x > √2 - 1 ≈ 0.4142. Puts |x| ≤ √2 - 1,
    //                   which is the optimal threshold for a
    //                   single (x-1)/(x+1) fold — the post-shift
    //                   max |new_x| = (1-t)/(1+t), equal to t
    //                   when t = √2 - 1.
    //
    // Over |y| ≤ √2 - 1, |y²| ≤ 0.1716 and 18 Horner terms push
    // the first omitted term to y³⁷/37 ≈ 4.5·10⁻¹⁶ — comfortably
    // under 2⁻⁴⁸ ≈ 3.55·10⁻¹⁵.
    //
    // atan is odd, so absorb the input sign up front and apply
    // it to the final result.
    static double atan(double x)
        {
        if (x == 0.0d)
            return 0.0d;

        bool neg = false;
        if (x < 0.0d)
            {
            x = 0.0d - x;
            neg = true;
            }

        bool recip = false;
        if (x > 1.0d)
            {
            x = 1.0d / x;
            recip = true;
            }

        bool shifted = false;
        double shiftThresh = Math.SQRT2() - 1.0d;
        if (x > shiftThresh)
            {
            x = (x - 1.0d) / (x + 1.0d);
            shifted = true;
            }

        // Horner on y², 18 terms — innermost coefficient first.
        double y2 = x * x;
        double s = -0.02857142857142857142857142857143d;   // -1/35
        s = 0.03030303030303030303030303030303d + y2 * s;  // +1/33
        s = -0.03225806451612903225806451612903d + y2 * s; // -1/31
        s = 0.03448275862068965517241379310345d + y2 * s;  // +1/29
        s = -0.03703703703703703703703703703704d + y2 * s; // -1/27
        s = 0.04d + y2 * s;                                // +1/25
        s = -0.04347826086956521739130434782609d + y2 * s; // -1/23
        s = 0.04761904761904761904761904761905d + y2 * s;  // +1/21
        s = -0.05263157894736842105263157894737d + y2 * s; // -1/19
        s = 0.05882352941176470588235294117647d + y2 * s;  // +1/17
        s = -0.06666666666666666666666666666667d + y2 * s; // -1/15
        s = 0.07692307692307692307692307692308d + y2 * s;  // +1/13
        s = -0.09090909090909090909090909090909d + y2 * s; // -1/11
        s = 0.11111111111111111111111111111111d + y2 * s;  // +1/9
        s = -0.14285714285714285714285714285714d + y2 * s; // -1/7
        s = 0.2d + y2 * s;                                 // +1/5
        s = -0.33333333333333333333333333333333d + y2 * s; // -1/3
        s = 1.0d + y2 * s;                                 // +1/1

        double result = x * s;

        if (shifted)
            result = Math.PI_4() + result;
        if (recip)
            result = Math.PI_2() - result;
        if (neg)
            result = 0.0d - result;
        return result;
        }

    // Double natural log. Same algorithm as ln(float): take k from
    // the IEEE exponent field and m from the mantissa, fold m into
    // [sqrt(2)/2, sqrt(2)), then a Horner-form atanh series on u²
    // with 15 reciprocal-odd coefficients (1/1, 1/3, …, 1/29).
    // |u| < 0.172 puts the first omitted term far below 2^-52.
    //
    // binary64 is little-endian: byte 7 holds the sign and exponent
    // bits 10..4, the high nibble of byte 6 holds exponent bits 3..0.
    // A subnormal input is scaled by 2^54 first.
    //
    // Non-positive inputs return 0 as a tame sentinel, matching the
    // float overload's contract; +inf and NaN are returned unchanged.
    static double ln(double val)
        {
        if (val == 0.0d)
            return 0.0d;
        if (val < 0.0d)
            return 0.0d;

        i16 k = 0;
        u8 hi;
        u8 lo;
        asm
        {
            LDA val+7
            STA hi
            LDA val+6
            STA lo
        }
        if (hi == 0 && (lo & $F0) == 0)
            {
            val = val * 18014398509481984.0d; // 2^54
            k = -54;
            asm
            {
                LDA val+7
                STA hi
                LDA val+6
                STA lo
            }
            }
        u16 e = ((u16)(hi & $7F) << 4) | (u16)(lo >> 4);
        if (e == $7FF)
            return val;
        k = k + (i16)e - 1023;

        // m = val with the exponent field set to the bias (1023), so
        // m = 1.mantissa ∈ [1, 2).
        double m = val;
        asm
            {
            LDA #$3F : STA m+7
            LDA val+6 : AND #$0F : ORA #$F0 : STA m+6
            }
        if (m > 1.4142135623730951d)
            {
            m = m * 0.5d;
            k = k + 1;
            }

        // u = (m - 1) / (m + 1), u² = u * u.
        double u = (m - 1.0d) / (m + 1.0d);
        double u2 = u * u;

        // Horner on atanh series, 15 terms with reciprocal-odd
        // coefficients.
        double sum = 0.0344827586206896551724d;     // 1/29
        sum = 0.0370370370370370370370d + u2 * sum; // 1/27
        sum = 0.0400000000000000000000d + u2 * sum; // 1/25
        sum = 0.0434782608695652173913d + u2 * sum; // 1/23
        sum = 0.0476190476190476190476d + u2 * sum; // 1/21
        sum = 0.0526315789473684210526d + u2 * sum; // 1/19
        sum = 0.0588235294117647058824d + u2 * sum; // 1/17
        sum = 0.0666666666666666666667d + u2 * sum; // 1/15
        sum = 0.0769230769230769230769d + u2 * sum; // 1/13
        sum = 0.0909090909090909090909d + u2 * sum; // 1/11
        sum = 0.1111111111111111111111d + u2 * sum; // 1/9
        sum = 0.1428571428571428571429d + u2 * sum; // 1/7
        sum = 0.2000000000000000000000d + u2 * sum; // 1/5
        sum = 0.3333333333333333333333d + u2 * sum; // 1/3
        sum = 1.0d + u2 * sum;                      // 1/1

        double lnm = 2.0d * u * sum;

        double kd = k;
        return lnm + kd * Math.LN2();
        }

    // Full-precision 48-bit natural exponential. Same structure
    // as exp(float) — halve until |x| ≤ 1, evaluate a Horner-form
    // Taylor series, then square `halvings` times to undo the
    // range reduction. |x|≤1 makes x^18/18! ≈ 1.6e-16 (below the
    // dp ULP 2^-48), so 18 terms give below-ULP accuracy.
    static double exp(double x)
        {
        u8 halvings = 0;
        double ax = x;
        if (ax < 0.0d)
            ax = 0.0d - ax;
        while (ax > 1.0d)
            {
            x = x * 0.5d;
            ax = ax * 0.5d;
            halvings = halvings + 1;
            if (halvings >= 30)
                {
                break;
                }
            }

        // Horner on Taylor series — 18 reciprocal-factorial
        // coefficients, starting with 1/17! (innermost) and
        // ending with two steps at coefficient 1 (1/1! and 1/0!).
        double sum = 0.00000000000000281145725434552076d;      // 1/17!
        sum = 0.0000000000000477947733238738529743d + x * sum; // 1/16!
        sum = 0.0000000000007647163731819816475901d + x * sum; // 1/15!
        sum = 0.0000000000114707455977297247138517d + x * sum; // 1/14!
        sum = 0.0000000001605904383682161459939238d + x * sum; // 1/13!
        sum = 0.0000000020876756987868098979210090d + x * sum; // 1/12!
        sum = 0.0000000250521083854417187750521084d + x * sum; // 1/11!
        sum = 0.0000002755731922398589065255731922d + x * sum; // 1/10!
        sum = 0.0000027557319223985890652557319224d + x * sum; // 1/9!
        sum = 0.0000248015873015873015873015873016d + x * sum; // 1/8!
        sum = 0.0001984126984126984126984126984127d + x * sum; // 1/7!
        sum = 0.0013888888888888888888888888888889d + x * sum; // 1/6!
        sum = 0.0083333333333333333333333333333333d + x * sum; // 1/5!
        sum = 0.0416666666666666666666666666666667d + x * sum; // 1/4!
        sum = 0.1666666666666666666666666666666667d + x * sum; // 1/3!
        sum = 0.5d + x * sum;                                  // 1/2!
        sum = 1.0d + x * sum;                                  // 1/1!
        sum = 1.0d + x * sum;                                  // 1/0! (x^0 = 1)

        // Square `halvings` times to undo the halving.
        u8 i;
        for (i = 0; i < halvings; i = i + 1)
            {
            sum = sum * sum;
            }

        return sum;
        }

    static double pow(double val, double power)
        {
        // Pure-dp implementation: mirror the float version's
        // `exp(power * ln(val))` but stay in 64-bit precision all
        // the way through. Dropping the old "cast to float, call
        // float pow, cast back" shortcut means programs that use
        // double pow no longer transitively link the 32-bit float
        // runtime — saves roughly 8 KB of code on xe where every
        // byte counts.
        if (power == 0.0d)
            return 1.0d;
        if (val == 0.0d)
            return 0.0d;
        if (val < 0.0d)
            return 0.0d;
        return Math.exp(power * Math.ln(val));
        }

    // pow(double, i16): full-precision binary exponentiation over
    // dpMul. Only reachable inside the outer #if ENABLE_DOUBLE, so
    // the dpMul runtime cost is paid only when the target has the
    // code budget for it.
    static double pow(double val, i16 power)
        {
        if (power == 0)
            return 1.0d;
        if (val == 0.0d)
            return 0.0d;

        bool negative_power = false;
        if (power < 0)
            {
            negative_power = true;
            power = 0 - power;
            }

        double result;
        bool have_result = false;
        double base = val;

        while (power > 0)
            {
            if ((power & 1) != 0)
                {
                if (have_result)
                    {
                    result = result * base;
                    }
                else
                    {
                    result = base;
                    have_result = true;
                    }
                }
            power = power >> 1;
            if (power > 0)
                {
                base = base * base;
                }
            }

        if (negative_power)
            {
            result = 1.0d / result;
            }
        return result;
        }

    // pow(double, i32) — wider exponent, same binary-exponentiation
    // algorithm. Reachability keeps this out of the binary unless a
    // caller actually passes an i32 exponent, so the i16-only user
    // pays nothing for it.
    static double pow(double val, i32 power)
        {
        if (power == 0)
            return 1.0d;
        if (val == 0.0d)
            return 0.0d;

        bool negative_power = false;
        if (power < 0)
            {
            negative_power = true;
            power = 0 - power;
            }

        double result;
        bool have_result = false;
        double base = val;

        while (power > 0)
            {
            if ((power & 1) != 0)
                {
                if (have_result)
                    {
                    result = result * base;
                    }
                else
                    {
                    result = base;
                    have_result = true;
                    }
                }
            power = power >> 1;
            if (power > 0)
                {
                base = base * base;
                }
            }

        if (negative_power)
            {
            result = 1.0d / result;
            }
        return result;
        }

    // pow(double, u32) — unsigned variant. No negative-exponent
    // branch; otherwise identical to the i32 form.
    static double pow(double val, u32 power)
        {
        if (power == 0)
            return 1.0d;
        if (val == 0.0d)
            return 0.0d;

        double result;
        bool have_result = false;
        double base = val;

        while (power > 0)
            {
            if ((power & 1) != 0)
                {
                if (have_result)
                    {
                    result = result * base;
                    }
                else
                    {
                    result = base;
                    have_result = true;
                    }
                }
            power = power >> 1;
            if (power > 0)
                {
                base = base * base;
                }
            }

        return result;
        }

    // ── Double-precision mathematical constants ──────────────────────
    // Zero-arg overloads of the float constant methods above. The
    // compiler's return-type-aware overload resolver picks the
    // double flavour in contexts where a double is expected:
    //   float  f = Math.PI();           // float overload
    //   double d = Math.PI();           // double overload
    //   double x = 2.0d * Math.PI();    // double (expected propagates
    //                                   //  through the binop)
    // When no context hint is available (vararg slot, expression
    // statement) the resolver falls back to the float overload.

    static double E(void)
        {
        return 2.718281828459048d;
        }
    static double LOG2E(void)
        {
        return 1.4426950408889638d;
        }
    static double LOG10E(void)
        {
        return 0.4342944819032519d;
        }
    static double LN2(void)
        {
        return 0.6931471805599454d;
        }
    static double LN10(void)
        {
        return 2.3025850929940432d;
        }
    static double PI(void)
        {
        return 3.1415926535897967d;
        }
    static double PI_2(void)
        {
        return 1.5707963267948983d;
        }
    static double PI_4(void)
        {
        return 0.7853981633974492d;
        }
    static double INV_PI(void)
        {
        return 0.3183098861837905d;
        }
    static double TWO_PI(void)
        {
        return 6.283185307179593d;
        }
    static double TWO_SQRTPI(void)
        {
        return 1.1283791670955132d;
        }
    static double SQRT2(void)
        {
        return 1.4142135623730958d;
        }
    static double SQRT1_2(void)
        {
        return 0.7071067811865479d;
        }
#endif // ENABLE_DOUBLE — the dp overload block
    }
