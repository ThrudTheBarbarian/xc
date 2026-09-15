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

// Platform.xc — the DEFAULT platform prelude (task #36).
//
// Auto-included before every compilation on targets whose platform lib has
// no Platform.xc of its own (platform-first include search: wasm32 and 6502
// shadow this file). Url, Log and Platform are therefore ambient on every
// target — the same app source compiles, links and runs everywhere. The
// generic defaults live in the classes themselves (ConsoleLogger for Log,
// no delegate for Platform — Url.fetch completes with status 0 after a
// logged warning until the app installs one), so this file only has to make
// the surface visible.

#import "PlatformCore.xc"
