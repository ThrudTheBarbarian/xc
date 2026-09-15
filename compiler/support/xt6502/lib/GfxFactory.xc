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

// GfxFactory.xc — single entry point for instantiating any
// Gfx subclass by mode constant. Lives in its own file so the
// caller pays only for the modes they import; pulling in the
// factory transitively pulls in every subclass it can construct.
//
// Usage:
//
//     #import "GfxFactory.xc"
//
//     Gfx* g = gfxCreate(GFX_320_192_1, 0);   // full-screen GR.8
//     g.setPen(1);
//     g.line(0, 0, 319, 191);
//
// `mode` is one of the resolution constants from Gfx.xc
// (GFX_320_192_1 / GFX_160_96_2 / …). `textRows` requests a
// split display with that many GR.0 text rows below the graphics
// region; pass 0 for a full-screen graphics display. Modes that
// don't support split-screen ignore `textRows`.
//
// Returns a Gfx* pointer to the leaf subclass instance, or null
// if the requested mode has no subclass implementation in this
// build. The caller owns the returned pointer (ARC retain on
// assignment, release / delete to free).
//
// Performance tip: when `mode` is a compile-time constant, prefer
// the inline form
//
//     Gfx* g = inline:gfxCreate(GFX_320_192_1, 0);
//
// The asm-level constant-fold + branch-elimination passes drop
// the dead subclass branches once the body is at the call site,
// shrinking a typical "factory + plot one pixel" program from
// ~9.8 KB to ~5.3 KB. A bare `gfxCreate(...)` call is fine for
// true runtime mode selection but pays the full factory cost
// (every subclass linked because the analyser conservatively
// marks all three branches as instantiated).

#import "Gfx.xc"
#import "Gfx7.xc"
#import "Gfx8.xc"
#import "Gfx15.xc"

Gfx* gfxCreate(u8 mode, u8 textRows)
    {
    if (mode == GFX_320_192_1)
        {
        if (textRows > 0)
            {
            Gfx8* g = new Gfx8(textRows);
            return (Gfx*)g;
            }
        Gfx8* g = new Gfx8();
        g.setupNative();
        return (Gfx*)g;
        }
    if (mode == GFX_160_96_2)
        {
        Gfx7* g = new Gfx7();
        g.setupNative();
        return (Gfx*)g;
        }
    if (mode == GFX_160_192_2)
        {
        Gfx15* g = new Gfx15();
        g.setupNative();
        return (Gfx*)g;
        }
    return (Gfx*)0;
    }
