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

// Process.xc — the command line, and the exit status.
// =================================================================
//
// Any host with the `_xt_` process primitives, alongside Files.xc, and for the
// same reason: a
// compiler written in xtc has to see the arguments it was invoked with and to
// fail with a non-zero status (private:docs/Design/self-hosting.md M4).
//
// An xtc `main` takes no parameters, so argc/argv are captured on the C side by
// a constructor — Darwin and glibc both pass (argc, argv, envp) to constructors,
// which is what makes this work without changing the generated entry point.

#import "Foundation.xc"

// Host primitives — standardised `_xt_` names, provided per host; see
// support/arm64/runtime/libxt.c and support/x86_64/runtime/sys-linux.s.
i32 _xt_argc(void);
u8* _xt_argv(i32 index);
void _xt_exit(i32 code);

class Process
    {
    u8 _unused; // no instances: every entry point is static

    void init(void)
        {
        _unused = (u8)0;
        }

    // Every argument INCLUDING argv[0], as Strings.
    static Array* arguments(void)
        {
        i32 n = _xt_argc();
        u32 count = (n > (i32)0) ? (u32)n : (u32)0;
        Array* out = Array.withCapacity(count);
        for (u32 i = (u32)0; i < count; i = i + (u32)1)
            out.add((Object*)String.withCString(_xt_argv((i32)i)));
        return out;
        }

    static u32 argumentCount(void)
        {
        i32 n = _xt_argc();
        return (n > (i32)0) ? (u32)n : (u32)0;
        }

    // The i'th argument, or an EMPTY String when there is none — a caller that
    // forgot to check the count gets "" rather than a null dereference.
    static String* argument(u32 i)
        {
        return String.withCString(_xt_argv((i32)i));
        }

    // Terminate now with this status. Nothing after it runs, including ARC
    // releases and defer blocks — it is `_exit`, not a return from main.
    static void exit(i32 code)
        {
        _xt_exit(code);
        }
    }
