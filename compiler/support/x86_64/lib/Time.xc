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

// Time.xc — x86_64 host port.
//
// The Atari port drives the RTCLOK jiffy counter; the host has none, so the
// timer reads a monotonic wall clock. The primitives (_xt_clk_reset / _xt_clk_ticks /
// _xt_clk_delay) come from the x86_64 C stub the driver emits and links
// (x86_64StubSource in src/xtc/main.m) — the same standardized names arm64's libxt.c
// and arm9's libxt-pic.c export. This class just calls them and does the arithmetic;
// no stubbed no-ops.
//
// Units: timerValue()/ticksSince() are microseconds since clearTimer() (the
// Atari uses 1/60 s jiffies). The raw tick is host-specific and opaque;
// portable code uses secondsSince() for real elapsed seconds. delayJiffies()
// takes jiffies (1/60 s) on every platform and waits real time.

// Mirrors the Atari Time.xc, which pulls in Math (callers like ahl.xc use
// Math.* and rely on importing Time to get it transitively).
#import "Math.xc"

// ── host time primitives, provided by libxt.a (no body here) ─────────
void _xt_clk_reset(void);        // set the elapsed-time origin to now
u32 _xt_clk_ticks(void);         // microseconds since the last reset
void _xt_clk_delay(u32 jiffies); // wait jiffies * (1/60 s) of real time

class Time
    {
    void init(void)
        {
        return;
        }

    // Reset the elapsed-time origin to "now".
    static void clearTimer(void)
        {
        _xt_clk_reset();
        }

    // Opaque timer value (microseconds since clearTimer on the host).
    static u32 timerValue(void)
        {
        return _xt_clk_ticks();
        }

    // Ticks (microseconds) elapsed since a prior timerValue().
    static u32 ticksSince(u32 oldValue)
        {
        return _xt_clk_ticks() - oldValue;
        }

    // Real seconds elapsed since a prior timerValue() (µs / 1e6).
    static float secondsSince(u32 oldValue)
        {
        u32 us = _xt_clk_ticks() - oldValue;
        float f = us;
        return f / 1000000.0;
        }

    // Wait `jiffies` * (1/60 s) of real wall time.
    static void delayJiffies(u32 jiffies)
        {
        _xt_clk_delay(jiffies);
        }
    }
