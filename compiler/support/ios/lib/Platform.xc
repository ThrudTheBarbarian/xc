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

// Platform.xc — iOS platform prelude (device and simulator).
//
// Auto-included before every `-A ios` / `-A ios-sim` compilation, searched
// BEFORE support/arm64/lib (iOS.md stage 4: the platform layer sits over the
// arm64 tree it shares the ISA and runtime with). The cross-platform surface
// (Url / Log / Platform) is the generic one; what is iOS-shaped lives here,
// backed by support/ios/runtime/xtios*.s (generated from
// src/xtc/support-src/xtios.c), which the driver links for these targets.
#import "PlatformCore.xc"

// The shim (xtios.c): the unified log, and NSURLSession driven from C.
void _xt_ios_log(u32 level, u8* msg);
u8* _xt_ios_fetch(u8* url, u32* status, u32* len);
void _xt_ios_free(u8* p); // the prelude claims no libc name: a program may declare its own

class Ios
    {
    // "ios" on a device, "ios-sim" on the simulator.
    static String* platform(void)
        {
#if PLATFORM_ios_sim
        return String.withCString("ios-sim");
#else
        return String.withCString("ios");
#endif
        }
    }

    // Log.info / warning / error → the console EXACTLY as the hosted default
    // prints it (so a program's output is the same here as on macOS) AND the
    // unified log (visible in `log stream` / Console.app). Installed lazily by
    // Log on this platform; Log.setLogger swaps it out as anywhere else.
    class IosLogger<Logger>
    {
    ConsoleLogger* _console;
    ConsoleLogger* console(void)
        {
        if (_console == 0)
            _console = new ConsoleLogger();
        return _console;
        }
    void error(String* msg)
        {
        console().error(msg);
        _xt_ios_log((u32)2, msg.cString());
        }
    void warning(String* msg)
        {
        console().warning(msg);
        _xt_ios_log((u32)1, msg.cString());
        }
    void info(String* msg)
        {
        console().info(msg);
        _xt_ios_log((u32)0, msg.cString());
        }
    }

    // The platform delegate. Url.fetch goes through NSURLSession (file://,
    // http://, https://), synchronously — Url.complete fires before fetch
    // returns, as the generic default's does; a failed request completes with
    // status 0 and a warning naming the URL. inject / pushState are browser
    // concepts and say so.
    class IosDelegate<PlatformDelegate>
    {
    void inject(String* sel, String* html)
        {
        Log.warning(String.withCString("Platform.inject: not a browser (iOS)"));
        }
    void pushState(String* url)
        {
        Log.warning(String.withCString("Platform.pushState: not a browser (iOS)"));
        }
    void startFetch(u32 token, Url* url)
        {
        String* s = url.toString();
        u32 status = (u32)0;
        u32 len = (u32)0;
        u8* bytes = _xt_ios_fetch(s.cString(), &status, &len);
        if (bytes == (u8*)0)
            {
            Log.warning(String.withFormat("Url.fetch(%s): the request failed - completing with status 0", s.cString()));
            Url.complete(token, (u32)0, (String*)0);
            return;
            }
        String* body = String.withCString(bytes);
        _xt_ios_free(bytes);
        Url.complete(token, status, body);
        }
    }
