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

// Vbi.xc — install / remove Vertical-Blank-Interrupt handlers.
//
// Atari 8-bit machines fire a VBI ~50 (PAL) or ~60 (NTSC) times a
// second. The OS dispatches first to the immediate-VBI vector
// (VVBLKI = $222) for time-critical work, then continues its own
// housekeeping (RTCLOK, key auto-repeat, attract mode, …) and
// finally jumps through the deferred-VBI vector (VVBLKD = $224)
// before exiting via XITVBV ($E462). Defaults: VVBLKI → SYSVBV
// ($E45F), VVBLKD → XITVBV ($E462).
//
// Usage:
//   void myHandler(void) :vbi { …body… }
//   Vbi.addDeferred(&myHandler);
//   …
//   Vbi.removeDeferred();
//
// The handler MUST be marked :vbi — that emits the A/X/Y save/
// restore wrap and the closing JMP XITVBV that lets the OS finish
// the interrupt. A plain function would corrupt registers and
// either lock up the machine or skip the OS chain.
//
// Install/remove always go through SETVBV ($E45C) so the OS does
// the SEI-safe pair-write to VVBLKI/VVBLKD — without that the VBI
// can fire between the lo and hi byte writes and call into the
// wrong half of the new pointer.
//
// Choose immediate when the work has tight timing (display-list
// updates, scroll registers — done before ANTIC starts the next
// frame) and deferred for everything else (counters, music, slow
// state machines).

class Vbi
    {
    u8 dummy;

    void init(void)
        {
        }

    // ── addImmediate: install fn at VVBLKI ($222) ───────────────────
    // SETVBV with A=6 atomically updates the immediate-VBI vector.

    static void addImmediate(pointer fn)
        {
        asm
        {
            LDY fn
            LDX fn+1
            LDA #$06
            JSR $E45C       ; SETVBV
        }
        }

    // ── addDeferred: install fn at VVBLKD ($224) ────────────────────
    // SETVBV with A=7 atomically updates the deferred-VBI vector.

    static void addDeferred(pointer fn)
        {
        asm
        {
            LDY fn
            LDX fn+1
            LDA #$07
            JSR $E45C       ; SETVBV
        }
        }

    // ── removeImmediate: restore VVBLKI to its OS default SYSVBV ────

    static void removeImmediate(void)
        {
        asm
        {
            LDY #$5F        ; <SYSVBV
            LDX #$E4        ; >SYSVBV
            LDA #$06
            JSR $E45C       ; SETVBV
        }
        }

    // ── removeDeferred: restore VVBLKD to its OS default XITVBV ─────

    static void removeDeferred(void)
        {
        asm
        {
            LDY #$62        ; <XITVBV
            LDX #$E4        ; >XITVBV
            LDA #$07
            JSR $E45C       ; SETVBV
        }
        }
    }
