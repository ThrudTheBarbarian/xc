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

// Time.xc — timer functions for xtc
// ===================================
//
// Usage (static — no instance needed):
//   #import <Time.xc>
//   #import <Math.xc>
//
//   Time.clearTimer();
//   // ... do work ...
//   u32 t0 = Time.timerValue();
//   // ... more work ...
//   u32 elapsed = Time.ticksSince(t0);
//   float secs  = Time.secondsSince(t0);
//
// Uses the Atari RTCLOK three-byte timer at $12/$13/$14:
//   $12 = high byte (increments every 65536 jiffies)
//   $13 = mid byte  (increments every 256 jiffies)
//   $14 = low byte  (increments every VBI — 50 Hz PAL, 60 Hz NTSC)
//
// secondsSince() requires the fpDiv runtime for the division — int→float
// conversion is now a built-in `float f = u32_or_u8_var;` assignment
// that the codegen lowers to a uX/iXToFp helper call automatically.
//
// PAL/NTSC detection reads GTIA register PAL ($D014):
//   If ($D014 & $0E) == 0 → PAL (50 Hz), else NTSC (60 Hz).

#import <Math.xc>

class Time
    {
    u8 dummy;

    void init(void)
        {
        }

    // ── clearTimer: reset RTCLOK to zero ─────────────────────────────

    static void clearTimer(void)
        {
        asm
        {
            LDA #$00
            STA $12
            STA $13
            STA $14
        }
        }

    // ── timerValue: read RTCLOK as a u32 ─────────────────────────────
    // Reads all three bytes in 9 cycles to minimise rollover risk.
    // Returns: $12 * 65536 + $13 * 256 + $14 as a little-endian u32.

    static u32 timerValue(void)
        {
        u32 result;
        asm
            {
                // Read all three bytes as fast as possible (9 cycles)
            LDA $14
            LDX $13
            LDY $12
                            // Pack into result: little-endian u32
            STA result
            STX result+1
            STY result+2
            LDA #$00
            STA result+3
            }
        return result;
        }

    // ── ticksSince: ticks elapsed since a previous timer value ────────

    static u32 ticksSince(u32 oldValue)
        {
        u32 now;
        asm
            {
                // Read timer fast then subtract inline
            LDA $14
            LDX $13
            LDY $12
            SEC
            SBC oldValue
            STA now
            TXA
            SBC oldValue+1
            STA now+1
            TYA
            SBC oldValue+2
            STA now+2
            LDA #$00
            SBC oldValue+3
            STA now+3
            }
        return now;
        }

    // ── secondsSince: seconds elapsed since a previous timer value ───
    // Reads timer, subtracts oldValue, converts elapsed ticks to float
    // via direct float-from-u32 assignment, detects PAL/NTSC, divides by the appropriate
    // Hz rate (50 or 60) via fpDiv.

    static float secondsSince(u32 oldValue)
        {
        u32 ticks;
        asm
            {
            LDA $14
            LDX $13
            LDY $12
            SEC
            SBC oldValue
            STA ticks
            TXA
            SBC oldValue+1
            STA ticks+1
            TYA
            SBC oldValue+2
            STA ticks+2
            LDA #$00
            SBC oldValue+3
            STA ticks+3
            }

        // Convert elapsed ticks to float (auto u32→float conversion)
        float fticks = ticks;

        // Detect PAL (50 Hz) or NTSC (60 Hz)
        u8 hz;
        asm
        {
            LDA $D014
            AND #$0E
            BNE .is_ntsc
            LDA #50
            JMP .hz_done
        .is_ntsc:
            LDA #60
        .hz_done:
            STA hz
        }

        // Convert Hz rate to float (auto u8→float conversion)
        float fhz = hz;

        // Divide: seconds = ticks / hz
        float result;
        asm
            {
            LDA fticks
            STA $B0
            LDA fticks+1
            STA $B1
            LDA fticks+2
            STA $B2
            LDA fticks+3
            STA $B3
            LDA fticks+4
            STA $B4
            LDA fhz
            STA $B5
            LDA fhz+1
            STA $B6
            LDA fhz+2
            STA $B7
            LDA fhz+3
            STA $B8
            LDA fhz+4
            STA $B9
            JSR fpDiv
            LDA $B0
            STA result
            LDA $B1
            STA result+1
            LDA $B2
            STA result+2
            LDA $B3
            STA result+3
            LDA $B4
            STA result+4
            }
        return result;
        }

    // ── dpSecondsSince: dp version of secondsSince ────────────────────
    // Named distinctly (rather than overloading secondsSince) because
    // xtc's overload resolution only uses return type as a tiebreaker
    // for zero-arg methods; a `secondsSince(u32) → float` and
    // `secondsSince(u32) → double` pair would be flagged as a
    // redefinition. Useful for very-long-running intervals where
    // float's ~7 digits of precision degrade timing granularity —
    // at 2 years uptime, float secondsSince resolves to ~10 s; dp
    // keeps full jiffy resolution across the u32 range.

    static double dpSecondsSince(u32 oldValue)
        {
        u32 ticks;
        asm
            {
            LDA $14
            LDX $13
            LDY $12
            SEC
            SBC oldValue
            STA ticks
            TXA
            SBC oldValue+1
            STA ticks+1
            TYA
            SBC oldValue+2
            STA ticks+2
            LDA #$00
            SBC oldValue+3
            STA ticks+3
            }

        double dticks = ticks;

        u8 hz;
        asm
        {
            LDA $D014
            AND #$0E
            BNE .dis_ntsc
            LDA #50
            JMP .dis_hzd
        .dis_ntsc:
            LDA #60
        .dis_hzd:
            STA hz
        }

        double dhz = hz;
        return dticks / dhz;
        }

    // ── delayJiffies: busy-wait for `jiffies` VBI ticks ──────────────
    // 1 jiffy = 1/50 s (PAL) or 1/60 s (NTSC). Uses RTCLOK so it's
    // unaffected by OS timer reloads and safely handles rollover.

    static void delayJiffies(u32 jiffies)
        {
        u32 start = Time.timerValue();
        while (Time.ticksSince(start) < jiffies)
            {
            }
        }

    // ── delaySeconds: busy-wait for `secs` seconds ───────────────────
    // Converts `secs` to a jiffy count (secs * Hz) using integer math
    // on the float's raw mantissa/exponent, then hands off to
    // delayJiffies. Detects PAL (50 Hz) / NTSC (60 Hz) from GTIA $D014.
    //
    // The 5-byte float is value = (1 + mantissa24/2^24) * 2^exp, with
    // the implicit leading 1 unstored. Let M = (1<<24) | mantissa24 as
    // a u32; then value * hz = (M * hz) >> (24 - exp). We compute M*hz
    // with a u32 shift-and-add (hz ≤ 60 < 2^6, M ≤ 2^25, so the u32
    // product never overflows), then shift right to yield jiffies.
    // Going through fpMul is not an option — it hangs on floats whose
    // stored mantissa is zero (e.g. 1.0 = {0,0,0,0,0}).

    static void delaySeconds(float secs)
        {
        u8 hz;
        asm
            {
            LDA $D014
            AND #$0E
            BNE .ds_ntsc
            LDA #50
            JMP .ds_hzd
        .ds_ntsc:
            LDA #60
        .ds_hzd:
            STA hz
            }

        u32 jiffies;
        u8 count;
        asm
            {
                // Negative → 0 jiffies
            LDA secs
            AND #$01
            BNE .ds_zero

                            // jiffies = M = (1<<24) | mantissa24
            LDA secs+4
            STA jiffies
            LDA secs+3
            STA jiffies+1
            LDA secs+2
            STA jiffies+2
            LDA #$01
            STA jiffies+3

                                                                        // acc ($B0..$B3) = jiffies * hz via shift-and-add on hz.
                                                                        // $B4 holds a working copy of hz that we LSR each round;
                                                                        // jiffies is shifted left in place to align the partial sums.
            LDA #$00
            STA $B0
            STA $B1
            STA $B2
            STA $B3
            LDA hz
            STA $B4
        .ds_mul_loop:
            LDA $B4
            BEQ .ds_mul_done
            LSR $B4
            BCC .ds_mul_noadd
            CLC
            LDA $B0
            ADC jiffies
            STA $B0
            LDA $B1
            ADC jiffies+1
            STA $B1
            LDA $B2
            ADC jiffies+2
            STA $B2
            LDA $B3
            ADC jiffies+3
            STA $B3
        .ds_mul_noadd:
            ASL jiffies
            ROL jiffies+1
            ROL jiffies+2
            ROL jiffies+3
            JMP .ds_mul_loop
        .ds_mul_done:
            LDA $B0
            STA jiffies
            LDA $B1
            STA jiffies+1
            LDA $B2
            STA jiffies+2
            LDA $B3
            STA jiffies+3

                                                                                                                                                                                                                  // Shift right by (24 - exp). exp is the signed byte in secs+1;
                                                                                                                                                                                                                  // negative exp (e.g. 0.5 → exp=-1) widens the shift correctly
                                                                                                                                                                                                                  // in unsigned 8-bit arithmetic (24 - 0xFF with borrow = 25).
                                                                                                                                                                                                                  // exp ≥ 25 would overflow u32 — clamp to 0 (no sane delay is
                                                                                                                                                                                                                  // that long).
            LDA secs+1
            BMI .ds_rshift
            CMP #25
            BCS .ds_zero
        .ds_rshift:
            STA count
            LDA #24
            SEC
            SBC count
            CMP #32 // shift ≥ 32 → result is 0
            BCS .ds_zero
            TAX
            BEQ .ds_done
        .ds_shr_loop:
            LSR jiffies+3
            ROR jiffies+2
            ROR jiffies+1
            ROR jiffies
            DEX
            BNE .ds_shr_loop
            JMP .ds_done

        .ds_zero:
            LDA #$00
            STA jiffies
            STA jiffies+1
            STA jiffies+2
            STA jiffies+3
        .ds_done:
            }

        Time.delayJiffies(jiffies);
        }
    }
