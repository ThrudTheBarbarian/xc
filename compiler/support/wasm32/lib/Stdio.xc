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

// Stdio.xc — wasm32 formatted text output (JS host).
// =========================================================
//
// This is the Stdio resolved for the native arm64 backend (on the
// include path ahead of support/generic/lib). It is keyed by the backend
// ARCHITECTURE — a future native x86_64 backend would add
// support/x86_64/lib — not by a single "host", since the build machine
// may be arm64 macOS or x86_64 Linux. Unlike the Atari Stdio it does NOT
// poke screen RAM and uses NO inline asm — it formats each value to
// ASCII and emits one byte at a time through the `_putc` runtime helper,
// which the generated JS loader wires to stdout (Node) / console (browser).
//
// The integer / string / hex / char output is byte-compatible with the
// Atari Stdio's text so the dual-backend corpus oracle agrees across
// targets: decimals carry no padding, %x is 4 uppercase hex digits, %lx
// is 8, etc. Float (%f / print(float)) formats to 6 decimal places and
// double (%lf / print(double)) to 10, matching the Atari fp2Asc / dp2Asc
// runtime (via the host `_xtc_pf` / `_xtc_pd` formatters). struct (%@)
// and enum (%e) formatting is still a single '?' placeholder. The cursor
// calls (setCursor / printfAt position) are no-ops: stdout is a byte
// stream with no addressable grid.
//
// Format specifiers (same as the Atari Stdio):
//   %d / %u   signed / unsigned 16-bit decimal
//   %x        unsigned 16-bit hex (4 digits, uppercase)
//   %ld %lu   signed / unsigned 32-bit decimal
//   %lx       unsigned 32-bit hex (8 digits)
//   %c        single character
//   %s        NUL-terminated string (u8*)
//   %f %lf    float (6 dp) / double (10 dp)
//   %e %@     enum / struct  — placeholder for now
//   %%        literal '%'

// Object root pulled in for the `%@` -> `obj.description()` dispatch.
// Gated on HAS_ATFMT so non-`%@` programs don't pull Object + String.
#if HAS_ATFMT
#import "Object.xc"
#endif

// Host console primitive: emit one byte to stdout. Declared extern
// (no body) — the linked host runtime / corpus C stub provides it.
void _putc(u8 c);

// Host float / double formatters: emit the value to stdout in the same
// fixed-point shape the Atari fp2Asc / dp2Asc runtime produces — 6
// decimal places for float, 10 for double (e.g. 1.5 → "1.500000",
// 1.5d → "1.5000000000"). Provided by the corpus C stub (printf %.*f).
void _xtc_pf(float f);
void _xtc_pd(double d);
// Precision-aware variants for `%.Nf` / `%.Nlf` — N=0 falls through to
// the historic 6 / 10 default in the stub.
void _xtc_pfp(float f, u8 precision);
void _xtc_pdp(double d, u8 precision);

// This platform has no second output stream — a 6502 has one screen, a wasm
// module one console — so a diagnostic goes where everything else goes. Named
// separately anyway so the CALLER does not have to know: `Stdio.error` means
// "this is a diagnostic" everywhere, and on a host it really is stderr.
void _putc_err(u8 c)
    {
    _putc(c);
    }

class Stdio
    {
    // A diagnostic line, on STDERR. It exists so a warning cannot land in the
    // middle of a DUMP: `xcc-fe --dump-ast` and friends write their artefact
    // to stdout, and the differentials compare that artefact byte for byte
    // (private:docs/Design/static-analysis.md §1).
    static void error(String* s)
        {
        if (s == (String*)0)
            return;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            _putc_err(s.byteAt(i));
        }

    // ── low-level emit helpers ───────────────────────────────────
    // Unsigned decimal, high digit first (recursive so no scratch
    // buffer / local array is needed).
    static void _emitU32(u32 v)
        {
        if (v >= (u32)10)
            {
            Stdio._emitU32(v / (u32)10);
            }
        _putc((u8)(v % (u32)10) + (u8)$30);
        }

    static void _emitI32(i32 v)
        {
        if (v < (i32)0)
            {
            _putc((u8)$2D); // '-'
            Stdio._emitU32((u32)(-v));
            }
        else
            {
            Stdio._emitU32((u32)v);
            }
        }

    // ── 64-bit decimal ───────────────────────────────────────────
    // Same recursive shape as the 32-bit pair, at the wider type. `%lld` had
    // nothing to print WITH before these: the format parser consumed `%l`,
    // found a second `l` matching none of d/u/x/f, printed the literal
    // character and consumed no argument — so every following argument
    // shifted by one.
    static void _emitU64(u64 v)
        {
        if (v >= (u64)10)
            {
            Stdio._emitU64(v / (u64)10);
            }
        _putc((u8)(v % (u64)10) + (u8)$30);
        }

    static void _emitI64(i64 v)
        {
        if (v < (i64)0)
            {
            _putc((u8)$2D); // '-'
            // Negating the most-negative value overflows, so the digits come
            // from the unsigned two's-complement magnitude instead.
            Stdio._emitU64((u64)0 - (u64)v);
            }
        else
            {
            Stdio._emitU64((u64)v);
            }
        }

    // Fixed-width hex, `digits` nibbles, high nibble first, uppercase.
    static void _emitHex(u32 v, u8 digits)
        {
        u8 i = digits;
        while (i != (u8)0)
            {
            i = i - (u8)1;
            u8 nib = (u8)((v >> ((u16)i * (u16)4)) & (u32)$0F);
            if (nib < (u8)10)
                {
                _putc(nib + (u8)$30);
                }
            // 'A'-10
            else
                {
                _putc(nib + (u8)$37);
                }
            }
        }

    // Fixed-width hex at 64 bits — `%llx`. Separate from the u32 form rather
    // than widening it: every existing caller passes a u32, and on the narrow
    // targets a 64-bit shift is out-of-line work they should not pay for.
    static void _emitHex64(u64 v, u8 digits)
        {
        u8 i = digits;
        while (i != (u8)0)
            {
            i = i - (u8)1;
            u8 nib = (u8)((v >> ((u64)i * (u64)4)) & (u64)$0F);
            if (nib < (u8)10)
                {
                _putc(nib + (u8)$30);
                }
            // 'A'-10
            else
                {
                _putc(nib + (u8)$37);
                }
            }
        }

    static void _emitStr(string s)
        {
        u8 c = *s;
        while (c != (u8)0)
            {
            _putc(c);
            s = s + 1;
            c = *s;
            }
        }

    // ── public print() overloads ─────────────────────────────────
    static void print(string s)
        {
        Stdio._emitStr(s);
        }
#if HAS_ATFMT
    // String* overload — forwards through the wrapped c-string. Gated
    // on HAS_ATFMT so non-`%@` programs don't pull String into scope.
    static void print(String* s)
        {
        Stdio._emitStr(s.cString());
        }
#endif
    static void print(u16 val)
        {
        Stdio._emitU32((u32)val);
        }
    static void print(i16 val)
        {
        Stdio._emitI32((i32)val);
        }
    static void print(u32 val)
        {
        Stdio._emitU32(val);
        }
    static void print(i32 val)
        {
        Stdio._emitI32(val);
        }
    // 6dp, matches fp2Asc
    static void print(float f)
        {
        _xtc_pf(f);
        }
    // 10dp, matches dp2Asc
    static void print(double d)
        {
        _xtc_pd(d);
        }
    static void print(float f, u8 precision)
        {
        _xtc_pfp(f, precision);
        }
    static void print(double d, u8 precision)
        {
        _xtc_pdp(d, precision);
        }

    static void printHex(u8 n)
        {
        Stdio._emitHex((u32)n, (u8)2);
        }
    static void printHex(u16 val)
        {
        Stdio._emitHex((u32)val, (u8)4);
        }
    static void printHex(u32 val)
        {
        Stdio._emitHex(val, (u8)8);
        }
    static void printHex(u64 val)
        {
        Stdio._emitHex64(val, (u8)16);
        }

    // Cursor positioning has no meaning on a byte stream.
    static void setCursor(u8 x, u8 y)
        {
        }
    static void init(void)
        {
        }
    // '?' (TODO)
    static void printStruct(void)
        {
        _putc((u8)$3F);
        }

    // ── printf ───────────────────────────────────────────────────
    // C's printf, with `%@` for an object's description(). The text is built
    // by String.withFormat — one formatter behind every format function, so
    // Stdio.printf and String.withFormat always agree — and written out.
    static void _putString(String* s)
        {
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            _putc(s.byteAt(i));
        }

    static void printf(string fmt, ...)
        {
        Stdio._putString(String.withFormat(fmt, ...));
        }

    // printfAt — positional output; on stdout the (x, y) is ignored.
    static void printfAt(u8 x, u8 y, string fmt, ...)
        {
        Stdio._putString(String.withFormat(fmt, ...));
        }
    }
