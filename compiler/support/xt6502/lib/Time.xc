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
    // Hz rate (50 or 60).

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

        return fticks / fhz;
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
    // jiffies = secs * Hz, truncated, in IEEE float on MECH. Hz is 50 (PAL)
    // or 60 (NTSC), from GTIA $D014. A negative, NaN or zero `secs` waits no
    // time; so does one whose jiffy count does not fit a u32.

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

        u32 jiffies = 0;
        if (secs > 0.0)
            {
            float j = secs * (float)hz;
            if (j < 4294967296.0)
                {
                jiffies = (u32)j;
                }
            }

        Time.delayJiffies(jiffies);
        }
    }
