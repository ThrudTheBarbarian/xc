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

// FILE.xc — Unix-style stream I/O.
//
// Single-import entry point for the FILE* abstraction and the
// C-style f* helpers. `#import "FILE.xc"` brings in:
//
//   * FILE          — abstract base class with virtual read /
//                     write / seek / close / eof / readChar /
//                     writeChar primitives. Subclasses override
//                     what they support.
//   * ConsoleOut    — writes to the screen via Stdio.putChar
//                     (cursor + scroll handled by the existing
//                     text-mode logic).
//   * ConsoleIn     — reads from the keyboard via Atari OS CIO
//                     IOCB 0 (E: device, line-buffered).
//   * Stream        — utility class with lazy stdout() / stdin()
//                     factories and the C-style fputc / fgetc /
//                     fputs / fgets / fread / fwrite / fseek /
//                     ftell / feof / ferror / fflush / fclose
//                     helpers that dispatch through FILE's vtable.
//                     getchar() / gets() are stdin shorthands.
//
// Cost model:
//   * Programs that don't `#import "FILE.xc"` pay nothing — no
//     vtable, no _virtual_dispatch helper, no Console* bodies.
//     `#import "Stdio.xc"` alone is byte-identical to before
//     this file existed.
//   * Programs that do `#import "FILE.xc"` pay for the vtable
//     and dispatch helper once. Concrete subclass bodies and
//     the singleton instances are reachability-trim friendly:
//     a program that only uses `Stream.stdout()` doesn't pull
//     ConsoleIn or its CIO call site.
//
// Usage:
//   #import "FILE.xc"
//   ...
//   FILE* out = Stream.stdout();
//   Stream.fputs("hello\n", out);
//
//   FILE* in = Stream.stdin();
//   u8 buf[80];
//   Stream.gets(&buf[0], (u16)80);

#import "Stdio.xc"

// Standard whence values mirror <stdio.h>:
#define SEEK_SET 0 // seek relative to start
#define SEEK_CUR 1 // seek relative to current position
#define SEEK_END 2 // seek relative to end (size + offset)

// EOF sentinel returned by single-byte reads.
#define EOF (i16) $FFFF

// _flags bits.
#define F_EOF $01 // last read hit end-of-stream
#define F_ERR $02 // last operation reported an error

// ─── FILE — abstract base class ────────────────────────────────
// Models the Unix-style FILE* abstraction. Default impls for the
// virtual primitives return EOF / no-op so a misconfigured FILE*
// fails visibly at the first f* call rather than silently.
class FILE
    {
    u16 _pos;  // logical position (bytes since open, or
               // absolute position for seekable backends)
    u8 _flags; // F_EOF / F_ERR bits

    void init(void)
        {
        _pos = (u16)0;
        _flags = (u8)0;
        return;
        }

    // Read up to `count` bytes into `buf`. Returns the actual byte
    // count read (0 at clean EOF), or EOF (-1) on error. Subclasses
    // should set F_EOF on a clean end-of-stream and F_ERR on a
    // genuine I/O error.
    i16 read(u8* buf, u16 count)
        {
        return EOF;
        }

    // Write `count` bytes from `buf`. Returns actual count written,
    // or EOF on error.
    i16 write(u8* buf, u16 count)
        {
        return EOF;
        }

    // Seek to a position. `whence` is SEEK_SET / SEEK_CUR / SEEK_END.
    // Returns the new position (≥ 0) or EOF if the stream is
    // unseekable (typical for keyboard / screen / network).
    i16 seek(i16 offset, u8 whence)
        {
        return EOF;
        }

    // Flush any pending output and release backend resources. After
    // close(), the FILE* should not be used. Subclasses with no
    // resource to release can leave this as the default no-op.
    void close(void)
        {
        return;
        }

    // True if the most recent read hit end-of-stream. Default reads
    // the F_EOF flag bit.
    bool eof(void)
        {
        return (_flags & (u8)F_EOF) != (u8)0;
        }

    // True if the most recent operation reported an error.
    bool error(void)
        {
        return (_flags & (u8)F_ERR) != (u8)0;
        }

    // Clear the EOF / error flags. Useful after a backend recovery
    // or before retrying reads on a stream that could grow (e.g. a
    // pipe being filled by another task).
    void clearerr(void)
        {
        _flags = (u8)0;
        return;
        }

    // ── Single-byte read / write — subclasses must override ───
    // The "obvious" default (`u8 buf[1]; buf[0] = c; write(&buf[0],
    // 1);`) tripped a ZP-aliasing hazard: xtc allocates the local
    // `buf` into the same ZP slot the callee's prologue uses for
    // its own params, so the address passed to write() points at
    // a byte the callee overwrites before reading. Rather than
    // patch around it (a class-level scratch ivar would lose its
    // bank byte on heap-w3), the contract is: every concrete FILE
    // subclass provides its own writeChar / readChar — usually a
    // single-instruction tail-call to the real I/O primitive.
    //
    // The defaults below return EOF so a subclass that forgets to
    // override gets a visible failure at the first fputc / fgetc
    // call instead of silent data loss.

    i16 readChar(void)
        {
        return EOF;
        }

    i16 writeChar(u8 c)
        {
        return EOF;
        }
    }

    // ─── ConsoleOut — write to the screen via Stdio.putChar ────────
    class ConsoleOut : FILE
    {
    void init(void)
        {
        super.init();
        return;
        }

    // Push `count` bytes from `buf` to the screen. Each byte goes
    // through Stdio.putChar so cursor handling and scroll honour
    // the existing text-mode logic.
    i16 write(u8* buf, u16 count)
        {
        u16 i = (u16)0;
        while (i < count)
            {
            Stdio.putChar(buf[i]);
            i = i + (u16)1;
            }
        _pos = _pos + count;
        return (i16)count;
        }

    // Single-byte fast path — bypass the buf[1] allocation in
    // FILE.writeChar by tail-calling Stdio.putChar directly.
    i16 writeChar(u8 c)
        {
        Stdio.putChar(c);
        _pos = _pos + (u16)1;
        return (i16)((u16)c);
        }
    }

    // ─── ConsoleIn — read from the keyboard via Atari OS E: ────────
    // Uses CIO IOCB 0 (always-open editor device). GETCHR is line-
    // buffered in the OS, so the OS handles backspace, cursor keys,
    // EOL termination ($9B). For raw single-key polling without line
    // editing, callers should use Atari's CH register ($02FC) directly.
    class ConsoleIn : FILE
    {
    void init(void)
        {
        super.init();
        return;
        }

    // Read up to `count` bytes into `buf` from IOCB 0 (E:).
    // Returns the actual byte count, 0 at EOF, EOF (-1) on error.
    // ATASCII newline ($9B) terminates a logical line; this
    // implementation reads one char per CIO call so callers see
    // the EOL byte and can decide what to do.
    i16 read(u8* buf, u16 count)
        {
        u16 n = (u16)0;
        while (n < count)
            {
            i16 c = readChar();
            if (c < (i16)0)
                {
                if (n == (u16)0)
                    return EOF;
                break;
                }
            buf[n] = (u8)((u16)c);
            n = n + (u16)1;
            }
        _pos = _pos + n;
        return (i16)n;
        }

    // Single-byte read via CIO IOCB 0 GETCHR ($07). Status returns
    // in Y; $01 = OK, $88 = EOF, anything else = error.
    i16 readChar(void)
        {
        u8 ch;
        u8 status;
        asm
        {
            LDX #$00              ; IOCB 0 (E:)
            LDA #$07              ; GETCHR
            STA $0342             ; ICCOM
            JSR $E456             ; CIOV
            STA ch
            STY status
        }
        if (status == (u8)$88)
            {
            _flags = _flags | (u8)F_EOF;
            return EOF;
            }
        if (status >= (u8)$80)
            {
            _flags = _flags | (u8)F_ERR;
            return EOF;
            }
        _pos = _pos + (u16)1;
        return (i16)((u16)ch);
        }
    }

    // ─── Stream — singletons + C-style f* helpers ─────────────────
    // Treated as a static utility class (like Stdio); the two
    // singleton ivars sit in the inline `__sdata_Stream` block. `new
    // Stream()` is supported but pointless — every method is static.
    class Stream
    {
    ConsoleOut* _stdoutInst; // offset 1 — lazy ConsoleOut singleton.
                             // Typed as the concrete subclass (not
                             // FILE*) because the upcast at the read
                             // site is free on 6502 (pointer width
                             // matches) while storing as FILE* would
                             // force an explicit downcast on retain.
    ConsoleIn* _stdinInst;   // offset 4 — lazy ConsoleIn singleton.

    // `:main` placement is load-bearing on xe-heap. A banked
    // function returning a freshly-allocated heap pointer hits a
    // codegen bug where the return path's PORTB / bank-byte
    // bookkeeping leaves the caller's bank wrong (separately
    // logged as an open xtc bug). Pinning these factories into
    // main RAM sidesteps it; the cost is small (factory bodies
    // only, not ConsoleOut / ConsoleIn themselves).
    static FILE* stdout(void) : main
        {
        if (_stdoutInst == (ConsoleOut*)0)
            {
            _stdoutInst = new ConsoleOut();
            }
        return (FILE*)_stdoutInst;
        }

    static FILE* stdin(void) : main
        {
        if (_stdinInst == (ConsoleIn*)0)
            {
            _stdinInst = new ConsoleIn();
            }
        return (FILE*)_stdinInst;
        }

    // Single-byte write. Returns the byte written (cast to i16),
    // or EOF on error. Mirrors C's `int fputc(int c, FILE *stream)`.
    static i16 fputc(u8 c, FILE* f)
        {
        return f.writeChar(c);
        }

    // Single-byte read. Returns the byte read in the low 8 bits,
    // or EOF (-1) at end-of-stream / error.
    static i16 fgetc(FILE* f)
        {
        return f.readChar();
        }

    // Read one byte from stdin. Convenience wrapper for the common
    // `fgetc(stdin())` shape — mirrors C's `int getchar(void)` (xtc
    // would shadow the namespace too noisily with two `getc`
    // overloads, so the bare zero-arg form lives under this name
    // and the C `getc(FILE*)` macro is just `Stream.fgetc(f)`).
    static i16 getchar(void)
        {
        return Stream.stdin().readChar();
        }

    // Write a null-terminated string to f. Returns 0 on success,
    // EOF on error. Does not append a newline (matching POSIX
    // fputs, not C++ std::fputs).
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

    // Read up to size-1 bytes from f into buf, stopping at the
    // first newline (kept) or EOF. Always null-terminates buf.
    // Returns buf on success, (u8*)0 if no bytes were read before
    // EOF / error. `size` MUST be >= 1.
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
                break; // newline (UNIX)
            if ((u8)((u16)c) == (u8)$9B)
                break; // ATASCII EOL
            }
        buf[n] = (u8)0;
        return buf;
        }

    // Read up to size-1 bytes from stdin into buf, same stopping
    // rules as fgets. Bounded form — the C `gets(char*)` is
    // unsafe (no length argument), so xtc deliberately follows
    // POSIX-strict and requires `size`.
    static u8* gets(u8* buf, u16 size)
        {
        return Stream.fgets(buf, size, Stream.stdin());
        }

    // Block read: read up to `count` bytes from f into buf.
    // Returns the number of bytes actually read (0 .. count),
    // or EOF on error. Subclasses decide whether short reads
    // are EOF (typical for files) or just "more data later"
    // (typical for sockets) — feof(f) disambiguates.
    static i16 fread(u8* buf, u16 count, FILE* f)
        {
        return f.read(buf, count);
        }

    // Block write: write `count` bytes from buf to f. Returns
    // the actual count written, or EOF on error.
    static i16 fwrite(u8* buf, u16 count, FILE* f)
        {
        return f.write(buf, count);
        }

    // Seek to a logical position. `whence` is SEEK_SET / SEEK_CUR
    // / SEEK_END. Returns the new position, or EOF if the stream
    // doesn't support seeking (keyboard, screen, sockets).
    static i16 fseek(FILE* f, i16 offset, u8 whence)
        {
        return f.seek(offset, whence);
        }

    // Current logical position. The default FILE._pos is updated
    // by ConsoleOut.write / ConsoleIn.read, so this works on
    // forward-only streams too.
    static i16 ftell(FILE* f)
        {
        return (i16)f._pos;
        }

    // True at end-of-stream. ConsoleIn sets F_EOF when the OS
    // reports EOF on E:. ConsoleOut never reaches EOF.
    static bool feof(FILE* f)
        {
        return f.eof();
        }

    // True if the last operation reported an error.
    static bool ferror(FILE* f)
        {
        return f.error();
        }

    // Flush pending writes. ConsoleOut is unbuffered (every
    // writeChar hits the screen immediately), so fflush is a
    // no-op for it. Custom subclasses with internal buffers
    // override their close() / a future flush() to drain.
    static void fflush(FILE* f)
        {
        return;
        }

    // Release the stream. After fclose(), the FILE* must not be
    // used. The singleton stdin / stdout instances are not freed
    // because programs typically keep using them through exit;
    // user-allocated FILE*s should be fclose'd by the owner.
    static void fclose(FILE* f)
        {
        f.close();
        return;
        }
    }
