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

// GApplication.xc — the application object and its event loop (Cocoa-style).
//
// A program's main() is tiny: create a GApplication, give it a delegate that
// adopts GApplicationProtocol, and call run(). run() hands off to the delegate
// (applicationDidStart) for app setup, then spins the event loop until stop()
// is called — at which point control returns to main() with an exit code.
//
//   void main(void) {
//       GApplication* app = new GApplication();
//       app.setDelegate(new GAppDelegate());
//       app.run(new Array());
//   }
//
// Milestone 1 wires the lifecycle end-to-end. The event SOURCE (GEM window
// manager + input) is stubbed in nextEvent() and lands next.
#import "Stdio.xc"
#import "Array.xc"
#import "GApplicationProtocol.xc"
#import "GEvent.xc"

class GApplication
    {
    GApplicationProtocol* delegate;
    bool running;

    void init(void)
        {
        delegate = (GApplicationProtocol*)0;
        running = false;
        }

    // Install the app delegate (any class adopting GApplicationProtocol).
    void setDelegate(GApplicationProtocol* d)
        {
        delegate = d;
        }

    // Ask the run loop to exit (a delegate or, later, an event handler calls
    // this to quit the application).
    void stop(void)
        {
        running = false;
        }

    // Pull the next event to dispatch. Milestone 1: there is no input source
    // under the qemu loader (the syscall surface is display-only), so this
    // synthesises a single Terminate to drain the loop cleanly. The real GEM
    // window-manager / input pump replaces this body next.
    GEvent* nextEvent(void)
        {
        GEvent* e = new GEvent();
        e.setKind((u8)GEventTerminate);
        return e;
        }

    // Cocoa-style entry point. Returns the application's exit code.
    i32 run(Array* args)
        {
        if (delegate == (GApplicationProtocol*)0)
            {
            Stdio.printf("GApplication: no delegate set\n");
            return (i32)1;
            }

        // Hand off to the app: this is where the user's code starts running.
        i32 rc = delegate.applicationDidStart(args);
        if (rc != (i32)0)
            {
            return rc; // app aborted startup
            }

        // Spin the event loop until something calls stop().
        running = true;
        while (running)
            {
            GEvent* ev = nextEvent();
            u8 k = ev.getKind();
            if (k == (u8)GEventTerminate)
                {
                running = false;
                }
            // (mouse / key / redraw dispatch to the responder chain — next.)
            }
        return (i32)0;
        }
    }
