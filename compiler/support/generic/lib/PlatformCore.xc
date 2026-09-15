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

// PlatformCore.xc — the platform seam's shared half (task #36).
//
// The Platform class is deliberately small: it holds the delegate and
// forwards the operations that have no home anywhere else (DOM-ish inject /
// pushState). The fetch registry lives with Url (it is fetch state); the
// logger lives with Log. Each platform PRELUDE (a file named Platform.xc —
// which is why this class lives in a differently-named file: platform-first
// include search would shadow a generic Platform.xc) imports this and
// answers the two hook functions with its defaults.
//
// A cross-platform app never names a platform: it calls Platform.inject /
// url.fetch / Log.info, and either the prelude wired a delegate (wasm32 →
// Browser) or the app installed its own via Platform.setDelegate.

#import "String.xc"
#import "Url.xc"
#import "Log.xc"

// The environment, read-only — see support/arm64/runtime/libxt.c and
// src/xtc/support-src/rt.c, which both define it so the clang and in-house
// runtimes cannot drift. Returns "" for a variable that is not set, never null,
// so a caller can test the LENGTH and never has to test for nil first.
u8* _xt_getenv(u8* name);

protocol PlatformDelegate
    {
    void inject(String * sel, String * html);
    void pushState(String * url);
    void startFetch(u32 token, Url * url);
    }

// The delegate, resolved LAZILY on first use: no delegate is the generic
// default, wasm32 constructs its Browser (declared by that platform's
// prelude, always earlier in the unit), and an app may install its own any
// time. Lazy rather than static-init so a program that never touches the
// platform allocates nothing before main; ARCH-gated here rather than
// hook-functioned because xtc rejects a bodyless declaration coexisting
// with its definition (task #36).
PlatformDelegate* _plat_delegate = (PlatformDelegate*)0;
bool _plat_wired = false;

class Platform
    {
    static PlatformDelegate* delegate(void)
        {
        if (!_plat_wired)
            {
#if ARCH_wasm32
            _plat_delegate = (PlatformDelegate*)new Browser();
#elif PLATFORM_ios
            _plat_delegate = (PlatformDelegate*)new IosDelegate();
#endif
            _plat_wired = true;
            }
        return _plat_delegate;
        }

    static void setDelegate(PlatformDelegate* d)
        {
        _plat_delegate = d;
        _plat_wired = true;
        }

    // An environment variable, or "" when unset. A shipped compiler has to find
    // what a user names by CONVENTION rather than by flag — $HOME/.xcc for the
    // signing-key cache first among them — and without this the xtc driver had
    // to be told the path on every command line.
    //
    // Not available where there is no environment to read: a 6502 or a bare
    // ARM9 has no process to inherit one, so those answer "" rather than
    // pretending. A caller that needs a real value must say so itself.
    static String* env(String* name)
        {
#if ARCH_6502 || ARCH_arm9 || ARCH_m68k || ARCH_wasm32
        return String.withCString("");
#else
        if (name == 0)
            return String.withCString("");
        return String.withCString(_xt_getenv(name.cString()));
#endif
        }

    // $HOME, or "" — the one lookup common enough to name.
    static String* home(void)
        {
        return Platform.env(String.withCString("HOME"));
        }

    static void inject(String* sel, String* html)
        {
        PlatformDelegate* d = Platform.delegate();
        if (d != 0)
            d.inject(sel, html);
        else
            Log.warning(String.withCString("Platform.inject: no platform delegate installed"));
        }

    static void pushState(String* url)
        {
        PlatformDelegate* d = Platform.delegate();
        if (d != 0)
            d.pushState(url);
        else
            Log.warning(String.withCString("Platform.pushState: no platform delegate installed"));
        }
    }
