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

// GApplicationProtocol.xc — the application-delegate contract (Cocoa-style).
//
// A user app provides a GAppDelegate class that adopts this protocol; the
// framework's GApplication drives it. This is the single point where the app's
// own code begins running: GApplication finishes its own setup, then calls
// applicationDidStart() and hands control back to the event loop.
//
//   class GAppDelegate <GApplicationProtocol> {
//       i32 applicationDidStart(Array* args) { ...; return 0; }
//   }
//
// (The `G` namespace mirrors Cocoa's `NS`; delegation is the spine of the
// framework — windows, menus and controls all report back through protocols
// like this one.)
#import "Array.xc"

protocol GApplicationProtocol
    {
    // Called once, after GApplication has initialised and before the event
    // loop spins. Set up the app's windows / state here. Return 0 to enter the
    // run loop; any non-zero value aborts startup and becomes the exit code.
    i32 applicationDidStart(Array * args);
    }
