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
//
// Levels: debug, info, warning, error (Log.levelDebug() … levelError()).
// Messages below Log.setMinLevel's level (info at first) are dropped, so
// Log.debug costs a comparison until it is wanted.
//
// Subsystems: Log.forSubsystem("net") is a LogChannel, one per name, with
// its own minimum level; its messages reach the Logger as "net: message".
//
// Monitors: Log.addMonitor(&watcher.onLog) calls back with the subsystem
// ("" for the plain facade), the level and the message of everything that
// passes the level filters, whatever the Logger does with it. A monitor's
// callback does not keep its receiver alive.

#import "String.xc"
#import "Stdio.xc"
#import "Array.xc"
#import "Map.xc"

protocol Logger
    {
    void error(String * msg);
    void warning(String * msg);
    void info(String * msg);
    // A Logger without it gets debug messages through info.
    optional void debug(String * msg);
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
    void debug(String* msg)
        {
        _emit("\x1B[2m", "\x1B[0m", "debug: ", msg);
        }
    }

Logger* _log_logger = (Logger*)0;
bool _log_wired = false;
u8 _log_minLevel = (u8)1;      // info
Map* _log_channels = (Map*)0;  // name -> LogChannel
Array* _log_monitors = (Array*)0;

class _LogMonitor
    {
    callback cb void(String* subsystem, u8 level, String* msg);
    }

// A named source of messages with its own minimum level: Log.forSubsystem.
class LogChannel
    {
    String* name;
    u8 minLevel;

    void setMinLevel(u8 level)
        {
        minLevel = level;
        }

    void log(u8 level, String* msg)
        {
        if (level >= minLevel)
            Log._send(name, level, msg);
        }

    void debug(String* msg)
        {
        log((u8)0, msg);
        }
    void info(String* msg)
        {
        log((u8)1, msg);
        }
    void warning(String* msg)
        {
        log((u8)2, msg);
        }
    void error(String* msg)
        {
        log((u8)3, msg);
        }
    void debug(string fmt, ...)
        {
        if (minLevel <= (u8)0 && _log_minLevel <= (u8)0)
            log((u8)0, String.withFormat(fmt, ...));
        }
    void info(string fmt, ...)
        {
        log((u8)1, String.withFormat(fmt, ...));
        }
    void warning(string fmt, ...)
        {
        log((u8)2, String.withFormat(fmt, ...));
        }
    void error(string fmt, ...)
        {
        log((u8)3, String.withFormat(fmt, ...));
        }
    }

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

    // ── Levels ───────────────────────────────────────────────────────────

    static u8 levelDebug(void)
        {
        return (u8)0;
        }
    static u8 levelInfo(void)
        {
        return (u8)1;
        }
    static u8 levelWarning(void)
        {
        return (u8)2;
        }
    static u8 levelError(void)
        {
        return (u8)3;
        }

    // Messages below `level` are dropped, from every channel (info at first).
    static void setMinLevel(u8 level)
        {
        _log_minLevel = level;
        }

    static u8 minLevel(void)
        {
        return _log_minLevel;
        }

    // ── Subsystems ───────────────────────────────────────────────────────

    // The channel named `name`, made on first use with a minimum of debug
    // (so only Log.setMinLevel filters it until it sets its own).
    static LogChannel* forSubsystem(String* name)
        {
        if (_log_channels == 0)
            _log_channels = new Map();
        LogChannel* c = (LogChannel* ?)_log_channels.get(name);
        if (c == 0)
            {
            c = new LogChannel();
            c.name = name;
            c.minLevel = (u8)0;
            _log_channels.set(name, c);
            }
        return c;
        }

    // ── Monitors ─────────────────────────────────────────────────────────

    static void addMonitor(callback cb void(String* subsystem, u8 level, String* msg))
        {
        if (_log_monitors == 0)
            _log_monitors = new Array();
        _LogMonitor* m = new _LogMonitor();
        m.cb = cb;
        _log_monitors.add(m);
        }

    static void removeMonitor(callback cb void(String* subsystem, u8 level, String* msg))
        {
        if (_log_monitors == 0)
            return;
        for (u32 i = (u32)0; i < _log_monitors.count(); i++)
            {
            _LogMonitor* m = (_LogMonitor*)_log_monitors.get(i);
            callback f void(String* subsystem, u8 level, String* msg) = m.cb;
            if (f == cb)
                {
                _log_monitors.removeAt(i);
                return;
                }
            }
        }

    // ── Sending ──────────────────────────────────────────────────────────

    // Every message ends here: the global level, the Logger, the monitors.
    static void _send(String* subsystem, u8 level, String* msg)
        {
        if (level < _log_minLevel || msg == 0)
            return;
        String* text = msg;
        if (subsystem != 0 && subsystem.byteLength() > (u32)0)
            {
            text = String.withString(subsystem);
            text.appendCString(": ");
            text.append(msg);
            }
        Logger* l = Log.logger();
        if (l != 0)
            {
            if (level >= (u8)3)
                l.error(text);
            else if (level == (u8)2)
                l.warning(text);
            else if (level == (u8)1)
                l.info(text);
            else
                {
                callback d void(String* m) = &l.debug;
                if (d)
                    d(text);
                else
                    l.info(text);
                }
            }
        if (_log_monitors != 0)
            {
            String* sub = subsystem == 0 ? String.withCString("") : subsystem;
            u32 i = (u32)0;
            while (i < _log_monitors.count())
                {
                _LogMonitor* m = (_LogMonitor*)_log_monitors.get(i);
                callback f void(String* subsystem, u8 level, String* msg) = m.cb;
                if (!f)
                    {
                    // Its receiver has gone.
                    _log_monitors.removeAt(i);
                    continue;
                    }
                f(sub, level, msg);
                i++;
                }
            }
        }

    // ── The plain facade ─────────────────────────────────────────────────

    static void error(String* msg)
        {
        Log._send((String*)0, (u8)3, msg);
        }
    static void warning(String* msg)
        {
        Log._send((String*)0, (u8)2, msg);
        }
    static void info(String* msg)
        {
        Log._send((String*)0, (u8)1, msg);
        }
    static void debug(String* msg)
        {
        Log._send((String*)0, (u8)0, msg);
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
    static void debug(string fmt, ...)
        {
        if (_log_minLevel == (u8)0)
            Log.debug(String.withFormat(fmt, ...));
        }
    }
