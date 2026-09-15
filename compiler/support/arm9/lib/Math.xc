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

// Math.xc — arm64 (native-codegen) math + PRNG.
// ==============================================
//
// The Math resolved for the native arm64 backend (ahead of
// support/generic/lib on the include path), keyed by backend
// ARCHITECTURE like the arm64 Stdio.xc / Heap.xc.
//
// Same PUBLIC API and method signatures as support/6502/lib/Math.xc
// — the frontend (preproc / sema / overload resolution / lowering) is
// shared across both backends, so the signatures must match exactly
// for overload resolution to behave identically; only the bodies
// differ. The Atari version drives the 6502 5-byte-float runtime
// (fpSqrt, fpAdd, …) through inline asm; this port uses NO inline asm:
//
//   • PRNG (setSeed / step / rand*): the same Marsaglia xorshift
//     (7, 9, 8) reimplemented in pure xtc on the 16-bit state, so the
//     sequence matches the Atari version bit-for-bit.
//   • Transcendentals (sqrt / sin / cos / tan / atan / ln / exp / pow):
//     thin wrappers over the host C library (libm), provided by the
//     corpus C stub as `_xm_*` externs (mirrors `_putc`).
//   • Constants: float / double literals (the Atari version's byte-list
//     {$..} encodings are 5-byte-Atari-format-specific and would not
//     decode on arm64's IEEE floats).
//
// abs() and the integer helpers are plain xtc arithmetic.

// ── Transcendentals: call the device libm.so directly (DT_NEEDED) ────
// The arm9 arch lib is the right home for this — no `_xm_*` C adapter to vend or
// duplicate. A bare call below resolves to these free functions, not the same-
// named Math methods. (sqrt[f] is special: the SqrtIntrinsic IR pass turns it
// into the FSqrt op → hardware `vsqrt`, with the libm call as the no-opt
// fallback. Math.ln maps to libm `log`.)
float sqrtf(float x);
double sqrt(double x);
float sinf(float x);
double sin(double x);
float cosf(float x);
double cos(double x);
float tanf(float x);
double tan(double x);
float atanf(float x);
double atan(double x);
float logf(float x);
double log(double x);
float expf(float x);
double exp(double x);
float powf(float a, float b);
double pow(double a, double b);

// ── PRNG: the device libc's srandom/random, called directly ──────────
// Auto-imported on arm9 (no #import <c>, no adapter to vend). random() is
// deterministically seeded (seed 1 on first use) for reproducibility; setSeed
// routes to srandom. The value is in [0,2^31-1], so it fits i32 and the rand()
// float/double overloads divide by 2147483648.0 == 2^31.

class Math
    {
    u8 seedLo;
    u8 seedHi;

    void init(void)
        {
        // Best-of-breed host build: the PRNG is the host's optimised libc
        // random() (via libxt.a), not a reimplemented xorshift. It seeds
        // deterministically on first use; nothing to do here. seedLo/seedHi
        // remain as the scratch the integer rand() overloads read after a
        // host draw (see step()).
        }

    // ── Seed the PRNG (delegates to the host) ────────────────────────
    static void setSeed(u16 seed)
        {
        srandom((u32)seed);
        }

    // ── Advance the state from the host PRNG ─────────────────────────
    // Pulls a 16-bit value from libc random() into seedLo/seedHi, so the
    // integer rand() overloads below are unchanged.
    static void step(void)
        {
        u16 s = (u16)random();
        seedLo = (u8)(s & $FF);
        seedHi = (u8)(s >> 8);
        }

    // ── rand (u8): 0..255 ────────────────────────────────────────────
    static u8 rand(void)
        {
        Math.step();
        return seedLo;
        }

    // ── rand (u16): 0..65535 ─────────────────────────────────────────
    static u16 rand(void)
        {
        Math.step();
        return (u16)seedLo + ((u16)seedHi << 8);
        }

    // ── rand (u8, bounded): 0..max inclusive ─────────────────────────
    static u8 rand(u8 max)
        {
        Math.step();
        u8 r = seedLo;
        if (max == $FF)
            {
            return r;
            }
        return r % (max + 1);
        }

    // ── rand (u8, range): lo..hi inclusive ───────────────────────────
    static u8 rand(u8 lo, u8 hi)
        {
        return lo + Math.rand(hi - lo);
        }

    // ── rand (u16, bounded): 0..max inclusive ────────────────────────
    static u16 rand(u16 max)
        {
        Math.step();
        u16 r = (u16)seedLo + ((u16)seedHi << 8);
        if (max == $FFFF)
            {
            return r;
            }
        return r % (max + 1);
        }

    // ── rand (u16, range): lo..hi inclusive ──────────────────────────
    static u16 rand(u16 lo, u16 hi)
        {
        return lo + Math.rand(hi - lo);
        }

    // ── rand (u32): 0..$FFFFFFFF ─────────────────────────────────────
    static u32 rand(void)
        {
        Math.step();
        u32 lo = (u32)seedLo + ((u32)seedHi << 8);
        Math.step();
        u32 hi = (u32)seedLo + ((u32)seedHi << 8);
        return lo + (hi << 16);
        }

    // ── rand (float): [0.5, 1.0) ─────────────────────────────────────
    // Matches the Atari version's range (exponent -1, random mantissa).
    static float rand(void)
        {
        // Inlined _xt_rand_f: 0.5 + (random()/2^31)*0.5, all f32 (matches the
        // C wrapper bit-for-bit) — but now visible to the IR inliner, so a hot
        // caller collapses to `bl random` + inline fp math like clang does.
        return 0.5 + ((float)random() / 2147483648.0) * 0.5;
        }

    // ── rand (double): [0.5, 1.0) ────────────────────────────────────
    static double rand(void)
        {
        // Inlined _xt_rand_d: 0.5 + (random()/2^31)*0.5 in f64 (2147483648.0d
        // == (double)RAND_MAX + 1.0). Same relocation as the float overload.
        return 0.5d + ((double)random() / 2147483648.0d) * 0.5d;
        }

    // ── sqrt ─────────────────────────────────────────────────────────
    static float sqrt(float val)
        {
        return sqrtf(val);
        }
    static double sqrt(double val)
        {
        return sqrt(val);
        }

    // ── abs ──────────────────────────────────────────────────────────
    static float abs(float val)
        {
        if (val < 0.0)
            {
            return -val;
            }
        return val;
        }

    static i8 abs(i8 val)
        {
        if (val < (i8)0)
            {
            return -val;
            }
        return val;
        }

    static i16 abs(i16 val)
        {
        if (val < (i16)0)
            {
            return -val;
            }
        return val;
        }

    static i32 abs(i32 val)
        {
        if (val < (i32)0)
            {
            return -val;
            }
        return val;
        }

    static double abs(double val)
        {
        if (val < 0.0d)
            {
            return -val;
            }
        return val;
        }

    // ── ln / exp ─────────────────────────────────────────────────────
    static float ln(float val)
        {
        return logf(val);
        }
    static float exp(float x)
        {
        return expf(x);
        }

    // ── pow (float) ──────────────────────────────────────────────────
    static float pow(float val, float power)
        {
        return powf(val, power);
        }
    static float pow(float val, i16 power)
        {
        return powf(val, (float)power);
        }

    // ── trig (float) ─────────────────────────────────────────────────
    static float sin(float angle)
        {
        return sinf(angle);
        }
    static float cos(float angle)
        {
        return cosf(angle);
        }
    static float tan(float angle)
        {
        return tanf(angle);
        }
    static float atan(float x)
        {
        return atanf(x);
        }

    // ── trig / transcendental (double) ───────────────────────────────
    static double sin(double angle)
        {
        return sin(angle);
        }
    static double cos(double angle)
        {
        return cos(angle);
        }
    static double tan(double angle)
        {
        return tan(angle);
        }
    static double atan(double x)
        {
        return atan(x);
        }
    static double ln(double val)
        {
        return log(val);
        }
    static double exp(double x)
        {
        return exp(x);
        }

    // ── pow (double) ─────────────────────────────────────────────────
    static double pow(double val, double power)
        {
        return pow(val, power);
        }
    static double pow(double val, i16 power)
        {
        return pow(val, (double)power);
        }
    static double pow(double val, i32 power)
        {
        return pow(val, (double)power);
        }
    static double pow(double val, u32 power)
        {
        return pow(val, (double)power);
        }

    // ── Math constants (zero-arg methods; float + double overloads) ──
    // xtc resolves the nullary float/double overloads by return-type
    // context — same as the Atari version.
    static float E(void)
        {
        return 2.71828182845904523536;
        }
    static float LOG2E(void)
        {
        return 1.44269504088896340736;
        }
    static float LOG10E(void)
        {
        return 0.43429448190325182765;
        }
    static float LN2(void)
        {
        return 0.69314718055994530942;
        }
    static float LN10(void)
        {
        return 2.30258509299404568402;
        }
    static float PI(void)
        {
        return 3.14159265358979323846;
        }
    static float PI_2(void)
        {
        return 1.57079632679489661923;
        }
    static float PI_4(void)
        {
        return 0.78539816339744830962;
        }
    static float INV_PI(void)
        {
        return 0.31830988618379067154;
        }
    static float TWO_PI(void)
        {
        return 6.28318530717958647692;
        }
    static float TWO_SQRTPI(void)
        {
        return 1.12837916709551257390;
        }
    static float SQRT2(void)
        {
        return 1.41421356237309504880;
        }
    static float SQRT1_2(void)
        {
        return 0.70710678118654752440;
        }

    static double E(void)
        {
        return 2.71828182845904523536d;
        }
    static double LOG2E(void)
        {
        return 1.44269504088896340736d;
        }
    static double LOG10E(void)
        {
        return 0.43429448190325182765d;
        }
    static double LN2(void)
        {
        return 0.69314718055994530942d;
        }
    static double LN10(void)
        {
        return 2.30258509299404568402d;
        }
    static double PI(void)
        {
        return 3.14159265358979323846d;
        }
    static double PI_2(void)
        {
        return 1.57079632679489661923d;
        }
    static double PI_4(void)
        {
        return 0.78539816339744830962d;
        }
    static double INV_PI(void)
        {
        return 0.31830988618379067154d;
        }
    static double TWO_PI(void)
        {
        return 6.28318530717958647692d;
        }
    static double TWO_SQRTPI(void)
        {
        return 1.12837916709551257390d;
        }
    static double SQRT2(void)
        {
        return 1.41421356237309504880d;
        }
    static double SQRT1_2(void)
        {
        return 0.70710678118654752440d;
        }
    }
