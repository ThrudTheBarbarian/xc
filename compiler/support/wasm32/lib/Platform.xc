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

// Platform.xc — wasm32 platform prelude (tasks #35/#36).
//
// Auto-included before every wasm32 compilation, shadowing the generic
// default. App source is platform-NEUTRAL: it calls `url.fetch(block …)`,
// `Platform.inject(…)`, `Log.info(…)` — the same lines that compile, link
// and run on every other target — and this file is what wires those seams
// to the browser: Browser is the PlatformDelegate, BrowserLogger is the
// Logger, and the generated loader carries the JS half of the `browser`
// package (any key in globalThis.xccImports.browser overrides a default).
//
// Browser-only surface stays on Browser (a hosted target never has it
// installed, so it never needs generalising). Async failure reaches the
// app's completion block as status 0 with a null String*.

#import "PlatformCore.xc"

#package browser
extern void _b_fetch(u32 token, u8* url, u32 ulen);
extern void _b_inject(u8* sel, u32 slen, u8* html, u32 hlen);
extern void _b_push_state(u8* url, u32 n);
extern void _b_log(u32 level, u8* p, u32 n); // 0 info / 1 warn / 2 error

class Browser<PlatformDelegate>
    {
    void inject(String* sel, String* html)
        {
        _b_inject(sel.cString(), sel.byteLength(),
                  html.cString(), html.byteLength());
        }

    void pushState(String* url)
        {
        _b_push_state(url.cString(), url.byteLength());
        }

    void startFetch(u32 token, Url* url)
        {
        // The loader decodes the url BEFORE awaiting anything — the pointer
        // is only guaranteed for the duration of this call.
        String* s = url.toString();
        _b_fetch(token, s.cString(), s.byteLength());
        }
    }

    class BrowserLogger<Logger>
    {
    void error(String* msg)
        {
        _b_log((u32)2, msg.cString(), msg.byteLength());
        }
    void warning(String* msg)
        {
        _b_log((u32)1, msg.cString(), msg.byteLength());
        }
    void info(String* msg)
        {
        _b_log((u32)0, msg.cString(), msg.byteLength());
        }
    }

    // No static-init wiring: the generic classes construct the wasm defaults
    // LAZILY under ARCH gates (see Log.logger / Platform.delegate), so a wasm
    // program that never logs or fetches allocates nothing before main — the
    // heap-introspection fixtures count live objects and a prelude that
    // front-loads two of them shifts every number (task #36).

    // The two entry points the loader's browser package calls back through —
    // exported definitions (§6). JS places the body bytes at
    // _xt_browser_alloc's result and calls _xt_browser_dispatch with the HTTP
    // status; p == 0 (status 0) reports a transport failure. The token → block
    // registry lives with Url, which is why this is one line.
    extern u8* _xt_browser_alloc(u32 n)
    {
    return new u8[n];
    }

extern void _xt_browser_dispatch(u32 token, u32 status, u8* p, u32 n)
    {
    String* body = (String*)0;
    if (p != 0)
        {
        body = String.withBytes(p, n);
        delete p;
        }
    Url.complete(token, status, body);
    }
