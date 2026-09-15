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

// FILE.xc — arm64 (native-codegen) Unix-style stream I/O.
// ========================================================
//
// The FILE resolved for the native arm64 backend (ahead of
// support/generic/lib on the include path), keyed by backend
// ARCHITECTURE like the arm64 Stdio.xc / Heap.xc / Math.xc.
//
// Same PUBLIC API and class shapes as support/6502/lib/FILE.xc (the
// shared frontend resolves dispatch identically). The only divergence
// is the backend of the console streams: the Atari version drives the
// OS CIO via inline 6502 asm (`JSR $E456`) and pokes screen RAM through
// Stdio.putChar; this port routes ConsoleOut straight through the host
// console primitive `_putc` (declared by Stdio.xc) — adding a putChar to
// the arm64 Stdio class perturbs codegen for unrelated fixtures — and
// stubs ConsoleIn to EOF, since the corpus arm64 runs have no
// interactive stdin. No inline asm.
//
// See support/6502/lib/FILE.xc for the full prose / cost model.

#import "Stdio.xc"

// Standard whence values mirror <stdio.h>:
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

// EOF sentinel returned by single-byte reads.
#define EOF (i16) $FFFF

// _flags bits.
#define F_EOF $01
#define F_ERR $02

// ─── FILE — abstract base class ────────────────────────────────
class FILE
    {
    u16 _pos;
    u8 _flags;

    void init(void)
        {
        _pos = (u16)0;
        _flags = (u8)0;
        return;
        }

    i16 read(u8* buf, u16 count)
        {
        return EOF;
        }
    i16 write(u8* buf, u16 count)
        {
        return EOF;
        }
    i16 seek(i16 offset, u8 whence)
        {
        return EOF;
        }
    void close(void)
        {
        return;
        }

    bool eof(void)
        {
        return (_flags & (u8)F_EOF) != (u8)0;
        }

    bool error(void)
        {
        return (_flags & (u8)F_ERR) != (u8)0;
        }

    void clearerr(void)
        {
        _flags = (u8)0;
        return;
        }

    // Single-byte primitives — concrete subclasses override (see the
    // Atari FILE.xc for the address-of-local hazard rationale). The
    // defaults return EOF so a missing override fails visibly.
    i16 readChar(void)
        {
        return EOF;
        }
    i16 writeChar(u8 c)
        {
        return EOF;
        }
    }

    // ─── ConsoleOut — write to host stdout via Stdio.putChar ───────
    class ConsoleOut : FILE
    {
    void init(void)
        {
        super.init();
        return;
        }

    i16 write(u8* buf, u16 count)
        {
        u16 i = (u16)0;
        while (i < count)
            {
            _putc(buf[i]);
            i = i + (u16)1;
            }
        _pos = _pos + count;
        return (i16)count;
        }

    i16 writeChar(u8 c)
        {
        _putc(c);
        _pos = _pos + (u16)1;
        return (i16)((u16)c);
        }
    }

    // ─── ConsoleIn — host stdin is not wired in the corpus ─────────
    // The Atari ConsoleIn reads IOCB 0 (E:) via CIO; the native corpus
    // runs are non-interactive, so reads report a clean EOF. (A future
    // host-stdin extern could replace this with a real `_getc`.)
    class ConsoleIn : FILE
    {
    void init(void)
        {
        super.init();
        return;
        }

    i16 read(u8* buf, u16 count)
        {
        _flags = _flags | (u8)F_EOF;
        return EOF;
        }

    i16 readChar(void)
        {
        _flags = _flags | (u8)F_EOF;
        return EOF;
        }
    }

    // ─── Stream — singletons + C-style f* helpers ─────────────────
    class Stream
    {
    ConsoleOut* _stdoutInst;
    ConsoleIn* _stdinInst;

    static FILE* stdout(void)
        {
        if (_stdoutInst == (ConsoleOut*)0)
            {
            _stdoutInst = new ConsoleOut();
            }
        return (FILE*)_stdoutInst;
        }

    static FILE* stdin(void)
        {
        if (_stdinInst == (ConsoleIn*)0)
            {
            _stdinInst = new ConsoleIn();
            }
        return (FILE*)_stdinInst;
        }

    static i16 fputc(u8 c, FILE* f)
        {
        return f.writeChar(c);
        }

    static i16 fgetc(FILE* f)
        {
        return f.readChar();
        }

    static i16 getchar(void)
        {
        return Stream.stdin().readChar();
        }

    static i16 fputs(string s, FILE* f)
        {
        u16 i = (u16)0;
        while (s[i] != (u8)0)
            {
            if (f.writeChar(s[i]) < (i16)0)
                return EOF;
            i = i + (u16)1;
            }
        return (i16)0;
        }

    static u8* fgets(u8* buf, u16 size, FILE* f)
        {
        if (size == (u16)0)
            return (u8*)0;
        u16 limit = size - (u16)1;
        u16 n = (u16)0;
        while (n < limit)
            {
            i16 c = f.readChar();
            if (c < (i16)0)
                {
                if (n == (u16)0)
                    return (u8*)0;
                break;
                }
            buf[n] = (u8)((u16)c);
            n = n + (u16)1;
            if ((u8)((u16)c) == (u8)$0A)
                break;
            if ((u8)((u16)c) == (u8)$9B)
                break;
            }
        buf[n] = (u8)0;
        return buf;
        }

    static u8* gets(u8* buf, u16 size)
        {
        return Stream.fgets(buf, size, Stream.stdin());
        }

    static i16 fread(u8* buf, u16 count, FILE* f)
        {
        return f.read(buf, count);
        }

    static i16 fwrite(u8* buf, u16 count, FILE* f)
        {
        return f.write(buf, count);
        }

    static i16 fseek(FILE* f, i16 offset, u8 whence)
        {
        return f.seek(offset, whence);
        }

    static i16 ftell(FILE* f)
        {
        return (i16)f._pos;
        }

    static bool feof(FILE* f)
        {
        return f.eof();
        }

    static bool ferror(FILE* f)
        {
        return f.error();
        }

    static void fflush(FILE* f)
        {
        return;
        }

    static void fclose(FILE* f)
        {
        f.close();
        return;
        }
    }
