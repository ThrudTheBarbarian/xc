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

// Log.xc — the cross-platform logging facade (task #36).
//
// Apps write `Log.info("connected %d", n)` on every target; where the bytes
// go is the platform's business. The `Logger` protocol carries the three
// severities; the `Log` class holds the Logger it calls through, and each
// platform prelude answers `_plat_default_logger()` with the right one —
// the browser console on wasm32, ConsoleLogger below on hosted targets.
// `Log.setLogger(myLogger)` swaps in an app's own at any time. (`use` is
// a keyword — the class-promotion statement — so not a method name.)
//
// The `(fmt, ...)` overloads live HERE on the facade, not in the protocol:
// String.withFormat renders once and the protocol only ever carries a
// finished String*, which keeps varargs out of itable dispatch entirely.

#import "String.xc"
#import "Stdio.xc"

protocol Logger
    {
    void error(String * msg);
    void warning(String * msg);
    void info(String * msg);
    }

#if ARCH_win64
// No tty probe on win64: ucrtbase.dll's isatty is unimplemented under wine
// (the sweep host), and the Windows console colour story is its own thing.
#else
#if ARCH_arm64 || ARCH_x86_64
// Hosted-only: tty detection for colouring, straight from the C library
// (the arm64 host links libSystem; x86_64 links the musl pool).
i32 isatty(i32 fd);
#endif
#endif

// The hosted default: severity prefixes, ANSI colour when stdout is a tty
// (red errors, yellow warnings), plain bytes when piped. On the small
// targets it is prefix-only — Stdio is a screen, not a tty.
class ConsoleLogger<Logger>
    {
    bool _colour;
    bool _decided;

    bool _tty(void)
        {
        if (!_decided)
            {
            _decided = true;
            _colour = false;
#if ARCH_win64
#else
#if ARCH_arm64 || ARCH_x86_64
            if (isatty((i32)1) != 0)
                _colour = true;
#endif
#endif
            }
        return _colour;
        }

    void _emit(string pre, string post, string tag, String* msg)
        {
        if (_tty())
            Stdio.print(pre);
        Stdio.print(tag);
        Stdio.print(msg.cString()); // print(string) exists on EVERY platform Stdio
        if (_tty())
            Stdio.print(post);
        Stdio.print("\n");
        }

    void error(String* msg)
        {
        _emit("\x1B[31m", "\x1B[0m", "error: ", msg);
        }
    void warning(String* msg)
        {
        _emit("\x1B[33m", "\x1B[0m", "warning: ", msg);
        }
    void info(String* msg)
        {
        _emit("", "", "", msg);
        }
    }

    Logger* _log_logger = (Logger*)0;
bool _log_wired = false;

class Log
    {
    // The default Logger, installed LAZILY on first use — a program that
    // never logs allocates nothing. The wasm32 arm is spelled here rather
    // than wired by the prelude at static-init for two reasons: xtc rejects
    // a bodyless hook declaration coexisting with its definition, and
    // static-init allocations would sit in every heap-introspection count.
    // BrowserLogger is declared by the wasm32 prelude, which is ALWAYS in
    // the unit before this file on that target.
    static Logger* logger(void)
        {
        if (!_log_wired)
            {
#if ARCH_wasm32
            _log_logger = (Logger*)new BrowserLogger();
#elif PLATFORM_ios
            _log_logger = (Logger*)new IosLogger();
#else
            _log_logger = (Logger*)new ConsoleLogger();
#endif
            _log_wired = true;
            }
        return _log_logger;
        }

    static void setLogger(Logger* l)
        {
        _log_logger = l;
        _log_wired = true;
        }

    static void error(String* msg)
        {
        Logger* l = Log.logger();
        if (l != 0)
            l.error(msg);
        }
    static void warning(String* msg)
        {
        Logger* l = Log.logger();
        if (l != 0)
            l.warning(msg);
        }
    static void info(String* msg)
        {
        Logger* l = Log.logger();
        if (l != 0)
            l.info(msg);
        }

    static void error(string fmt, ...)
        {
        Log.error(String.withFormat(fmt, ...));
        }
    static void warning(string fmt, ...)
        {
        Log.warning(String.withFormat(fmt, ...));
        }
    static void info(string fmt, ...)
        {
        Log.info(String.withFormat(fmt, ...));
        }
    }
