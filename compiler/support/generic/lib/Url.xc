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

// Url.xc — a URL as a value (the NSURL-ish class), plus the cross-platform
// fetch seam (task #36).
//
// `url.fetch(block void(u32 status, String* body) { … })` is the SAME line
// of application source on every target. The transport comes from the
// platform delegate (PlatformCore.xc): the wasm32 prelude installs Browser,
// a hosted app may install its own HTTP-backed delegate, and with no
// delegate the completion fires synchronously with status 0 after a logged
// warning — the code still compiles, links and runs everywhere, which is
// the point.
//
// Status: an HTTP status when the transport supplies one; 0 means "no
// transport" or a transport-level failure (body is null then).

#import "String.xc"
#import "Log.xc"
#import "PlatformCore.xc"

// One in-flight fetch: token → completion block. A hand-linked list keeps
// the prelude's dependency surface at String alone.
class FetchReq
    {
    u32 token;
    block cb void(u32, String*);
    FetchReq* next;

    void fire(u32 status, String* body)
        {
        cb(status, body);
        }
    }

    FetchReq* _url_reqs = (FetchReq*)0;
u32 _url_next_token = (u32)1;

class Url
    {
    String* _raw;

    static Url* withString(String* s)
        {
        Url* u = new Url();
        u._raw = String.withString(s);
        return u;
        }

    static Url* withCString(u8* s)
        {
        return Url.withString(String.withCString(s));
        }

    String* toString(void)
        {
        return _raw;
        }

    // ── light accessors (byte scans, no allocation beyond the result) ────
    // scheme "http" | host "a.b:8080"→"a.b" | port 8080 (0 = none) |
    // path "/x/y" ("/" when absent) | query "k=v" ("" when absent).

    String* scheme(void)
        {
        u32 i = _find(String.withCString("://"), (u32)0);
        if (i == (u32)0xFFFFFFFF)
            return String.withCString("");
        return _raw.substringBytes((u32)0, i);
        }

    String* host(void)
        {
        u32 s = _afterScheme();
        u32 e = s;
        u8* b = _raw.cString();
        while (e < _raw.byteLength() && b[e] != (u8)'/' && b[e] != (u8)'?' && b[e] != (u8)':')
            {
            e = e + (u32)1;
            }
        return _raw.substringBytes(s, e - s);
        }

    u32 port(void)
        {
        u32 s = _afterScheme();
        u8* b = _raw.cString();
        u32 e = s;
        while (e < _raw.byteLength() && b[e] != (u8)'/' && b[e] != (u8)'?' && b[e] != (u8)':')
            {
            e = e + (u32)1;
            }
        if (e >= _raw.byteLength() || b[e] != (u8)':')
            return (u32)0;
        u32 p = (u32)0;
        e = e + (u32)1;
        while (e < _raw.byteLength() && b[e] >= (u8)'0' && b[e] <= (u8)'9')
            {
            p = p * (u32)10 + (u32)(b[e] - (u8)'0');
            e = e + (u32)1;
            }
        return p;
        }

    String* path(void)
        {
        u32 s = _afterScheme();
        u8* b = _raw.cString();
        while (s < _raw.byteLength() && b[s] != (u8)'/' && b[s] != (u8)'?')
            s = s + (u32)1;
        if (s >= _raw.byteLength() || b[s] == (u8)'?')
            return String.withCString("/");
        u32 e = s;
        while (e < _raw.byteLength() && b[e] != (u8)'?')
            e = e + (u32)1;
        return _raw.substringBytes(s, e - s);
        }

    String* query(void)
        {
        u32 i = _find(String.withCString("?"), (u32)0);
        if (i == (u32)0xFFFFFFFF)
            return String.withCString("");
        return _raw.substringBytes(i + (u32)1, _raw.byteLength() - i - (u32)1);
        }

    // ── the fetch seam ───────────────────────────────────────────────────

    void fetch(block cb void(u32, String*))
        {
        FetchReq* r = new FetchReq();
        r.token = _url_next_token;
        _url_next_token = _url_next_token + (u32)1;
        r.cb = cb;
        r.next = _url_reqs;
        _url_reqs = r;
        PlatformDelegate* d = Platform.delegate();
        if (d == 0)
            {
            Log.warning(Url.noTransportWarning(self));
            Url.complete(r.token, (u32)0, (String*)0);
            return;
            }
        d.startFetch(r.token, self);
        }

    // The completion entry every transport calls back through — the wasm32
    // prelude's exported dispatch, or a hosted delegate directly. Unknown
    // tokens are ignored (a completion can race a teardown).
    // The one wording for "nothing here can fetch that": the generic default
    // (no delegate) and a platform delegate without a transport for the
    // scheme (iOS today) say the same thing, so a program's output does not
    // depend on which of the two it hit.
    static String* noTransportWarning(Url* u)
        {
        return String.withFormat("Url.fetch(%s): no transport for this URL - completing with status 0",
                                 u.toString().cString());
        }
    static void complete(u32 token, u32 status, String* body)
        {
        FetchReq* prev = (FetchReq*)0;
        FetchReq* r = _url_reqs;
        while (r != 0 && r.token != token)
            {
            prev = r;
            r = r.next;
            }
        if (r == 0)
            return;
        if (prev == 0)
            _url_reqs = r.next;
        else
            prev.next = r.next;
        r.fire(status, body);
        // Unlinked above; the local's scope exit is the last release.
        }

    // ── internals ────────────────────────────────────────────────────────

    u32 _afterScheme(void)
        {
        u32 i = _find(String.withCString("://"), (u32)0);
        return i == (u32)0xFFFFFFFF ? (u32)0 : i + (u32)3;
        }

    u32 _find(String* needle, u32 from)
        {
        u32 n = needle.byteLength();
        if (n == (u32)0 || n > _raw.byteLength())
            return (u32)0xFFFFFFFF;
        u8* h = _raw.cString();
        u8* nd = needle.cString();
        u32 last = _raw.byteLength() - n;
        u32 i = from;
        while (i <= last)
            {
            u32 j = (u32)0;
            while (j < n && h[i + j] == nd[j])
                j = j + (u32)1;
            if (j == n)
                return i;
            i = i + (u32)1;
            }
        return (u32)0xFFFFFFFF;
        }
    }
