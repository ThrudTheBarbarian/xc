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

// Platform.xc — Atari ST/TT (m68k) platform prelude.
//
// Auto-included before every m68k compilation so the system-dependent parts of
// a program live HERE, and the user's source stays platform-agnostic.
//
// Placeholder: no native bindings yet. This is the seam where the Atari GEM
// backend would reach the real AES/VDI — the ORIGINAL GEM — via its GEMDOS/
// line-A traps, so the AES (form_do, objc_draw, …) and VDI signatures belong
// here. On this target "looks like a GEM program" is literal.

// The cross-platform surface (Url / Log / Platform — task #36): ambient on
// every target, defaults wired lazily in the classes themselves.
#import "PlatformCore.xc"
