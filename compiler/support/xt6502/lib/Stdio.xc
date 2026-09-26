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

// Stdio.xc — formatted text output class for xtc
// ==================================================

// Object root pulled in for the `%@` -> `obj.description()` dispatch.
// Gated on the printf-format pre-scan: programs that never use `%@`
// don't pay the Object + String class footprint (preproc gate works
// since phase #177; the xt6502 bank packer absorbs the added code into
// a new bank since phase #176 — see those commit messages).
#if HAS_ATFMT
#import "Object.xc"
#endif

// printStruct's recursion saves its 6-byte frames on one of two
// stacks, selected by the driver macro XTC_LIB_HWSTACK:
//
//   XTC_LIB_HWSTACK = 1  → the CPU hardware stack (PHA/PLA).
//        Used by cloak-capable targets (PORTB unmaps the software-
//        stack window mid-cloak) and by xt (4 KB hidden hardware
//        stack — its only stack; it defines no XTC_SP at all).
//   XTC_LIB_HWSTACK = 0  → the xtc *software* stack via XTC_SP_LO/HI,
//        a ZP pointer the driver defines for flat/standard targets
//        whose 256-byte hardware stack is too shallow for deep
//        recursion. xl: $82 / $83.
//
// XTC_SP_LO/HI therefore exist only on the software-stack targets;
// the #if XTC_LIB_HWSTACK guards below keep xt from ever naming them.

//
// Usage (static — no instance needed):
//   Stdio.printf("Hello %s!", name);
//   Stdio.printfAt(10, 5, "Score: %d", score);
//
// Usage (instance — stack-allocated, auto-reclaimed at scope exit):
//   Stdio p;
//   p.printf("Hello %s!", name);
//
// Or the explicit heap-allocated form:
//   Stdio* p = new Stdio();
//   p.printf("Hello %s!", name);
//
// The init method reads the Atari OS variables:
//   $57       — screen mode (DINDEX)
//   $58/$59   — screen RAM base address (SAVMSC)
//
// Text modes: GR.0 = 40 columns, GR.1/2/3 = 20 columns.
// Graphics modes (4+) have no text output; printf silently does nothing.
//
// Class state is stored inline in the
// code segment (via __sdata_Stdio), so no ZP or heap is consumed
// for static calls. Works in both standard and banked modes.
//
// Format specifiers:
//   %d   signed 16-bit integer
//   %u   unsigned 16-bit integer
//   %x   unsigned 16-bit hex (4 digits, uppercase)
//   %ld  signed 32-bit integer
//   %lu  unsigned 32-bit integer
//   %lx  unsigned 32-bit hex (8 digits, uppercase)
//   %c   single ATASCII character (u8) — control codes are acted on
//   %s   ATASCII string (u8*)
//   %f   float (IEEE binary32) — printed by printFpDec
//   %e   text version enum if possible to resolve
//   %@   struct/class (data ptr + descriptor ptr)
//   %%   literal '%'
//
// The compiler packs vararg data (everything after the format string)
// into the printf slot of the shared varargs buffer pool; printf
// walks it back out via the language-level `va_start` / `va_arg_*`
// / `va_end` intrinsics — the same public API any user varargs
// function uses.

// XTC_CLOAKED expands to `: cloaked` on cloak-capable targets and
// to nothing on flat targets. Used to force the heavy methods
// (init, scroll, putChar, print(*), printHex(*), printf, etc.)
// into the cloaked library bank on every xe-family layout — the
// canonical xe canonical 8 KB main-RAM region can't accommodate
// the full Stdio surface in main otherwise. On xl/xt the macro
// is empty; methods stay default-placement and land in main RAM.
#if XTC_HAS_CLOAKED
#define XTC_CLOAKED : cloaked
#else
#define XTC_CLOAKED
#endif

#if XTC_HAS_CLOAKED
// Cloaked decimal formatter for u16. Stage 4b.
//
// Lives outside the class so it uses the banked free-function calling
// convention (val arrives in $B0/$B1, no hw-stack param-pop dance in
// the prologue) and so it doesn't pay for the method-level frame
// save/restore — neither of which would survive PORTB = $30, because
// the xtc software stack gets mapped out when banking is off. Writes
// a NUL-terminated ASCII decimal at XT_STDIO_FMT_BUF, in the printf-buffer tail
// that sema leaves unused past slot 4. The caller flushes via
// Stdio._flush() once PORTB is restored.
//
// Locals stay in ZP (leaf pool or fixed). val/10 + val%10 lower
// to JSR u16Div / u16Mod which live in main RAM and stay
// reachable from cloaked context (main RAM is always visible
// regardless of PORTB). The earlier hand-rolled subtract loop
// was 44× slower on val=65535 and ~225 bytes larger.
void _printfU16(u16 val) : cloaked
    {
    u16 quo;
    u8 rem;
main:
    u8* out;
main:
    u8* p;
main:
    u8* q;
    u8 tmp;

    out = (main : u8*)XT_STDIO_FMT_BUF;
    p = out;

    // val/10 + val%10 emit JSR u16Div + JSR u16Mod (~150 cycles
    // each). The previous subtract-counted form
    // `while (val >= 10) val -= 10;` was O(val/10) iterations —
    // ~7300 trips for val=65535 — and ~225 bytes larger than this
    // form. u16Div / u16Mod live in main RAM and are reachable
    // from cloaked context (main RAM stays visible regardless of
    // PORTB).
    while (1)
        {
        quo = val / 10;
        rem = (u8)(val % 10);
        *p = rem + $30;
        p = p + 1;
        val = quo;
        if (val == 0)
            {
            break;
            }
        }
    *p = 0;

    // Reverse the digits in place: lo walks forward from out, hi
    // walks back from the last digit (one before the NUL).
    p = p - 1;
    q = out;
    while (q < p)
        {
        tmp = *q;
        *q = *p;
        *p = tmp;
        q = q + 1;
        p = p - 1;
        }
    }

// Cloaked 4-digit hex formatter for u16. Writes "ABCD\0" at XT_STDIO_FMT_BUF
// (uppercase, always 4 digits, leading zeros preserved). Same
// free-function rationale as _printfU16 above: avoids the method
// prologue's hw-stack PLA dance that wouldn't survive PORTB=$30.
void _printfHexU16(u16 val) : cloaked
    {
main:
    u8* out;
    u8 n;

    out = (main : u8*)XT_STDIO_FMT_BUF;

    n = (u8)((val >> 12) & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;

    n = (u8)((val >> 8) & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;

    n = (u8)((val >> 4) & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;

    n = (u8)(val & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;

    *out = 0;
    }

// Cloaked 8-digit hex formatter for u32. Writes "AABBCCDD\0" at
// XT_STDIO_FMT_BUF (uppercase, always 8 digits, leading zeros preserved).
// Decomposes the u32 into two u16 halves; each half is peeled in
// four 4-bit nibbles. No runtime-asm helpers needed — the shifts
// and masks all inline.
void _printfHexU32(u32 val) : cloaked
    {
main:
    u8* out;
    u16 hi;
    u16 lo;
    u8 n;

    out = (main : u8*)XT_STDIO_FMT_BUF;
    hi = (u16)((val >> 16) & $FFFF);
    lo = (u16)(val & $FFFF);

    n = (u8)((hi >> 12) & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;
    n = (u8)((hi >> 8) & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;
    n = (u8)((hi >> 4) & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;
    n = (u8)(hi & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;

    n = (u8)((lo >> 12) & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;
    n = (u8)((lo >> 8) & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;
    n = (u8)((lo >> 4) & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;
    n = (u8)(lo & $0F);
    if (n < 10)
        {
        *out = n + $30;
        }
    else
        {
        *out = n + $37;
        }
    out = out + 1;

    *out = 0;
    }

// Cloaked decimal formatter for u32. Same algorithm as _printfU16
// but uses u32 / 10 and u32 % 10 — those expand to JSRs into the
// u32Div / u32Mod runtime helpers. Thanks to the stage-4b helper-
// promotion pass, u32Div / u32Mod get placed in the cloaked segment
// if no main-bank code needs them; otherwise they stay in main and
// we JSR to them there (main RAM is always visible, and the asm
// helpers are ZP-only).
//
// A u32 max-value "4294967295" fits comfortably in the XT_STDIO_FMT_BUF..$05FF
// tail. The reverse-in-place at the end is unchanged from the u16
// formatter — we write digits low-to-high, then swap from ends.
void _printfU32(u32 val) : cloaked
    {
    u32 quo;
    u8 rem;
    u8 idx;
main:
    u8* out;
main:
    u8* p;
main:
    u8* q;
    u8 tmp;

    out = (main : u8*)XT_STDIO_FMT_BUF;
    p = out;
    idx = 0;

    while (1)
        {
        quo = val / (u32)10;
        rem = (u8)(val % (u32)10);
        *p = rem + $30;
        p = p + 1;
        idx = idx + 1;
        val = quo;
        if (val == (u32)0)
            {
            break;
            }
        }
    *p = 0;

    p = p - 1;
    q = out;
    while (q < p)
        {
        tmp = *q;
        *q = *p;
        *p = tmp;
        q = q + 1;
        p = p - 1;
        }
    }
#endif

class Stdio
    {
    // A diagnostic line, on STDERR. It exists so a warning cannot land in the
    // middle of a DUMP: `xcc-fe --dump-ast` and friends write their artefact
    // to stdout, and the differentials compare that artefact byte for byte
    // (private:docs/Design/static-analysis.md §1).
    static void error(String* s)
        {
        // A 6502 has one screen, so a diagnostic goes where everything else
        // goes. The NAME still exists here so a caller never has to know which
        // platform it is on: `Stdio.error` means "this is a diagnostic"
        // everywhere, and on a host it really is a second stream.
        if (s == (String*)0)
            return;
        for (u32 i = (u32)0; i < s.byteLength(); i = i + (u32)1)
            Stdio.putChar(s.byteAt(i));
        }

    u16 screenPtr;       // offset 0
    u16 screenBase;      // offset 2
    u8 cols;             // offset 4
    u8 mode;             // offset 5
    u8 canPrint;         // offset 6
    main : u8* fpBufPtr; // offset 7 — unused; kept so later ivar offsets stay put.
                         // Held as an ivar so it survives the putChar
                         // call inside print(float) / print(double);
                         // a ZP local would be clobbered by putChar's
                         // own locals (the ZP allocator hands both
                         // functions the same slots, and xtc doesn't
                         // save locals around calls — only parameters).
                         // `main:` pins these to 2-byte main-RAM
                         // pointers so the default-placement flip on
                         // banked-heap targets (increment 8) doesn't
                         // widen them to 3-byte banked pointers —
                         // everything they index is in main RAM.
    main : u8* psDp;     // offset 9  — printStruct data pointer (live across putChar)
    main : u8* psDesc;   // offset 11 — printStruct descriptor pointer
    u8 psFieldCount;     // offset 13 — printStruct field count
    u8 psIdx;            // offset 14 — printStruct loop index (live across print() calls)
    main : u8* psSaveDp; // offset 15 — scratch used when pushing a nested
                         // frame: for type-8 (inline struct) it holds the
                         // post-struct psDp so the pop restores to the
                         // parent's next field; for type-9 (class
                         // pointer) it holds the child's data pointer
                         // read from the parent's bytes, so the child
                         // walk can swap psDp over to it.
    u8 rows;             // offset 17 — text region row count. Read
                         // from BOTSCR ($02BF) at init time so a
                         // smaller text strip (e.g. setupSplit(4))
                         // is honoured automatically. Used by
                         // putChar to detect end-of-screen and
                         // call scroll(). Tail-of-class so adding
                         // it doesn't shift the older ivar
                         // offsets that the runtime references
                         // through `_ivar_Stdio_*` symbols.

    // ── Auto-init: reads screen mode and base from OS ────────────────
    // Called automatically by 'new Stdio()' since it matches the
    // zero-argument initialiser signature.

    void init(void) XTC_CLOAKED
        {
        u8 lo;
        u8 hi;
        u8 scrMode;

        // Read screen mode from DINDEX ($57)
        asm
            {
            LDA $57
            STA scrMode
            }
        mode = scrMode;

        // Read screen base from SAVMSC ($58/$59)
        u16 sbase;
        asm
            {
            LDA $58
            STA sbase
            LDA $59
            STA sbase+1
            }
        screenBase = sbase;
        screenPtr = sbase;

        // Determine columns from mode
        if (mode == 0)
            {
            cols = 40;
            canPrint = 1;
            }
        else if (mode < 4)
            {
            // Modes 1, 2, 3 = 20-column text
            cols = 20;
            canPrint = 1;
            }
        else
            {
            // Modes 4+ are graphics — no text output
            cols = 0;
            canPrint = 0;
            }

        // Read row count from BOTSCR ($02BF) — Atari OS's
        // text-window row count (1-based: full-screen GR.0
        // boots to 24, a Gfx8.setupSplit(n) caller writes n
        // before first printf so scroll() walks only the
        // active text strip). Treat 0 as "uninitialised
        // (xts default), fall back to 24".
        u8 botlin;
        asm
        {
            LDA $02BF
            STA botlin
        }
        if (botlin == 0)
            {
            rows = 24;
            }
        else
            {
            rows = botlin;
            }
        }

    // ── Scroll the text region up by one row ────────────────────
    // Source row k (1..rows-1) copies into row k-1; the last
    // row is then filled with screen-code 0 (space). Stays
    // entirely within screenBase + cols * rows so a setupSplit
    // text strip can't bleed into surrounding RAM.

    static void scroll(void) XTC_CLOAKED
        {
        // Compute the byte ranges in xtc, then run the move +
        // tail-clear in a tight asm block. The xtc-level
        // version compiled to several hundred bytes of u16
        // bookkeeping which overflowed the xt-heap main code
        // region; this asm form is ~50 bytes of body and runs
        // a clean DEX/BNE loop pair.
        u16 sb = screenBase;
        u16 numCols = (u16)cols;
        u16 size = numCols * (u16)(rows - 1);
        u16 src = sb + numCols;
        u16 dst = sb;
        u8 szLo = (u8)(size & $FF);
        u8 szHi = (u8)(size >> 8);
        u8 cLo = (u8)numCols;
        asm
        {
            ; Set up indirect pointers in $B0/$B1 (dst) and
            ; $B2/$B3 (src). The runtime-params region $B0-$BF
            ; is reserved against ZP-allocated locals so dst /
            ; src can't collide with anything sema gave us.
            LDA dst
            STA $B0
            LDA dst+1
            STA $B1
            LDA src
            STA $B2
            LDA src+1
            STA $B3
            ; ---- Move (rows-1)*cols bytes up by one row ----
            ; Outer loop uses szHi pages (256-byte chunks) plus
            ; an inner DEX/BNE for szLo trailing bytes. Y is
            ; the byte offset within the current page. After
            ; each page wrap we INC the high bytes of both
            ; pointers and walk the next 256 bytes.
            LDX szHi
            BEQ _stdio_scroll_tail
            LDY #$00
        _stdio_scroll_page:
            LDA ($B2),Y
            STA ($B0),Y
            INY
            BNE _stdio_scroll_page
            INC $B1
            INC $B3
            DEX
            BNE _stdio_scroll_page
        _stdio_scroll_tail:
            LDX szLo
            BEQ _stdio_scroll_clear
            LDY #$00
        _stdio_scroll_tail_lp:
            LDA ($B2),Y
            STA ($B0),Y
            INY
            DEX
            BNE _stdio_scroll_tail_lp
            ; Advance the dst pointer past the bytes we just
            ; copied so the bottom-row clear lands at the
            ; right address. Y holds the byte offset we ended
            ; on; CLC + ADC walks $B0 forward.
            CLC
            TYA
            ADC $B0
            STA $B0
            BCC _stdio_scroll_clear
            INC $B1
        _stdio_scroll_clear:
            ; Clear numCols bytes (cLo, always less than 256)
            ; at the dst's current location to give the new
            ; bottom row a blank screen-code-0 fill.
            LDX cLo
            BEQ _stdio_scroll_done
            LDY #$00
            LDA #$00
        _stdio_scroll_clear_lp:
            STA ($B0),Y
            INY
            DEX
            BNE _stdio_scroll_clear_lp
        _stdio_scroll_done:
        }
        }

    // ── Write one byte to screen memory and advance cursor ───────────
    // Performs ATASCII → screen code conversion.

    static void putChar(u8 ch) XTC_CLOAKED
        {
        u8 sc;
        u8 inv;

        if (canPrint == 0)
            {
            return;
            }

        // End-of-screen wrap: when the cursor has advanced past
        // the last byte of the text region (rows*cols bytes from
        // screenBase), scroll the whole region up by one row and
        // back the cursor up onto the now-empty bottom row.
        u16 endPtr = screenBase + (u16)cols * (u16)rows;
        u16 ptr = screenPtr;
        if (ptr >= endPtr)
            {
            scroll();
            screenPtr = endPtr - (u16)cols;
            ptr = screenPtr;
            }

        // Handle newline: advance to start of next row. Don't
        // pre-emptively scroll if the cursor lands right at endPtr
        // — the top-of-putChar check above will scroll on the NEXT
        // output instead. That way `printf("...\n")` on the bottom
        // row leaves all visible lines (including the just-printed
        // one) on screen until something else asks to print, which
        // matches Atari BASIC's PRINT-then-scroll order. The
        // out-of-bounds risk is contained because no character
        // write can happen while screenPtr == endPtr — every
        // putChar entry guards on `ptr >= endPtr`.
        if (ch == $0A)
            {
            u16 off;
            u16 rem;
            off = ptr - screenBase;
            rem = off % cols;
            ptr = ptr + (cols - rem);
            screenPtr = ptr;
            return;
            }

        inv = ch & $80;
        ch = ch & $7F;

        if (ch < $20)
            {
            sc = ch + $40;
            }
        else if (ch < $40)
            {
            sc = ch - $20;
            }
        else if (ch < $60)
            {
            sc = ch - $20;
            }
        else
            {
            sc = ch;
            }

        sc = sc | inv;
        // An address held in an INTEGER, written through a pointer. The sema
        // deref rule now rejects a bare `*someInt` on every target: the idiom
        // is real but 6502-only, and two lines here were not worth weakening
        // the rule for all eight. This spelling is already the house style in
        // this file (`out = (main:u8*)XT_STDIO_FMT_BUF;`). screenPtr stays a
        // u16 — its ivar offset is hand-documented (0, screenBase at 2, …), so
        // widening it would shift the whole ZP layout.
        *(main : u8*)screenPtr = sc;
        screenPtr = screenPtr + 1;
        }

    // ── Overloaded print: string and decimal integer variants ───────
    // All scalar decimal printers resolve under the single `print`
    // name; sema picks the right overload from the argument's type.
    // Hex printing stays under `printHex` because it's a different
    // verb (same type, different rendering).

    static void print(string s) XTC_CLOAKED
        {
        u8 ch;
        if (canPrint == 0)
            {
            return;
            }
        ch = *s;
        while (ch != 0)
            {
            putChar(ch);
            s = s + 1;
            ch = *s;
            }
        }

#if HAS_ATFMT
    // String* overload — forwards through the wrapped c-string. Gated
    // on HAS_ATFMT so a non-`%@` program doesn't need String in scope.
    static void print(String* s) XTC_CLOAKED
        {
        print(s.cString());
        }
#endif

#if XTC_HAS_CLOAKED
    // Brackets a call to the cloaked _printfU16 formatter, then walks
    // the NUL-terminated result at XT_STDIO_FMT_BUF through putChar. Flush is
    // inlined rather than split into its own method: a dedicated
    // `:main` method would pay the full frame-save/restore prologue
    // (pushing locals to the xtc stack), and in a main-RAM-constrained
    // target (e.g. `double_math_trig` on xe) that overhead is what
    // pushes the program over the code-region budget. Folding it into
    // print(u16) keeps one set of pushes for all the local state.
    static void print(u16 val) XTC_CLOAKED
        {
        u8 ch;
    main:
        u8* p;

        _printfU16(val);

        if (canPrint == 0)
            {
            return;
            }
        p = (main : u8*)XT_STDIO_FMT_BUF;
        ch = *p;
        while (ch != 0)
            {
            putChar(ch);
            p = p + 1;
            ch = *p;
            }
        }
#else
    static void print(u16 val) XTC_CLOAKED
        {
        u16 d;
        u8 r;
        if (val >= 10)
            {
            d = val / 10;
            print(d);
            }
        r = val % 10;
        putChar(r + $30);
        }
#endif

    static void print(i16 val) XTC_CLOAKED
        {
        if (val < 0)
            {
            putChar($2D);
            val = 0 - val;
            }
        // Cast so the u16 overload fires on the reflected positive
        // value rather than recursing into this i16 overload.
        print((u16)val);
        }

#if XTC_HAS_CLOAKED
    // xe: route through the cloaked _printfU32 formatter, then flush
    // the NUL-terminated result at XT_STDIO_FMT_BUF via putChar. Same shape as
    // print(u16) — see that overload's comment for why the flush is
    // inlined rather than split into its own method.
    static void print(u32 val) XTC_CLOAKED
        {
        u8 ch;
    main:
        u8* p;

        _printfU32(val);

        if (canPrint == 0)
            {
            return;
            }
        p = (main : u8*)XT_STDIO_FMT_BUF;
        ch = *p;
        while (ch != 0)
            {
            putChar(ch);
            p = p + 1;
            ch = *p;
            }
        }
#else
    static void print(u32 val) XTC_CLOAKED
        {
        u32 d;
        u8 r;
        if (val >= 10)
            {
            d = val / 10;
            print(d);
            }
        r = val % 10;
        putChar(r + $30);
        }
#endif

    static void print(i32 val) XTC_CLOAKED
        {
        if (val < 0)
            {
            putChar($2D);
            val = 0 - val;
            }
        print((u32)val);
        }

    // ── 64-bit decimal ───────────────────────────────────────────
    // Same recursive shape as print(u32)/print(i32), at the wider type. Only
    // reached by `%lld` / `%llu`, so a program that never uses them never
    // links the 64-bit divide this needs.
    static void print(u64 val) XTC_CLOAKED
        {
        u64 d;
        u8 r;
        if (val >= (u64)10)
            {
            d = val / (u64)10;
            print(d);
            }
        r = (u8)(val % (u64)10);
        putChar(r + $30);
        }

    static void print(i64 val) XTC_CLOAKED
        {
        if (val < (i64)0)
            {
            putChar($2D);
            // Negating the most-negative value overflows; take the unsigned
            // two's-complement magnitude instead.
            print((u64)0 - (u64)val);
            return;
            }
        print((u64)val);
        }

    // ── Print one hex nibble (0-F) ───────────────────────────────────

    static void printHex(u8 n) XTC_CLOAKED
        {
        if (n < 10)
            {
            putChar(n + $30);
            }
        else
            {
            putChar(n + $37);
            }
        }

    // ── Print unsigned 16-bit as 4 hex digits ────────────────────────

#if XTC_HAS_CLOAKED
    // xe: same split as print(u16). _printfHexU16 formats into XT_STDIO_FMT_BUF
    // from the cloaked bank; this wrapper flushes it byte by byte.
    static void printHex(u16 val) XTC_CLOAKED
        {
        u8 ch;
    main:
        u8* p;

        _printfHexU16(val);

        if (canPrint == 0)
            {
            return;
            }
        p = (main : u8*)XT_STDIO_FMT_BUF;
        ch = *p;
        while (ch != 0)
            {
            putChar(ch);
            p = p + 1;
            ch = *p;
            }
        }
#else
    static void printHex(u16 val) XTC_CLOAKED
        {
        printHex((u8)((val >> 12) & $0F));
        printHex((u8)((val >> 8) & $0F));
        printHex((u8)((val >> 4) & $0F));
        printHex((u8)(val & $0F));
        }
#endif

    // ── Print unsigned 32-bit as 8 hex digits ────────────────────────

#if XTC_HAS_CLOAKED
    // xe: route through the cloaked _printfHexU32 formatter, then
    // flush the NUL-terminated 8-digit result at XT_STDIO_FMT_BUF via putChar.
    static void printHex(u32 val) XTC_CLOAKED
        {
        u8 ch;
    main:
        u8* p;

        _printfHexU32(val);

        if (canPrint == 0)
            {
            return;
            }
        p = (main : u8*)XT_STDIO_FMT_BUF;
        ch = *p;
        while (ch != 0)
            {
            putChar(ch);
            p = p + 1;
            ch = *p;
            }
        }
#else
    static void printHex(u32 val) XTC_CLOAKED
        {
        printHex((u16)((val >> 16) & $FFFF));
        printHex((u16)(val & $FFFF));
        }
#endif

    // ── Float / double printing via MECH ─────────────────────────────
    // The math coprocessor gives IEEE f32/f64 arithmetic, so a float now
    // prints by MECH digit extraction — no fp2Asc/dp2Asc softfloat formatter.
    // printFpDec extracts |v|'s integer part and its fractional digits (all via
    // MECH float ops), rounds half-up at decimal place `roundAt`, and prints the
    // first `keep`. This mirrors the native oracle exactly: bare %f/%lf round at
    // the default width (keep==roundAt==6 / 10), while `%.Nf`/`%.Nlf` round at
    // N+1 then keep N (keep=N, roundAt=N+1) — the `_xtc_pfp`/`_xtc_pdp` stubs'
    // "snprintf %.(N+1)f then drop the last digit" behaviour.
    static void printFpDec(double v, u8 keep, u8 roundAt) XTC_CLOAKED
        {
        u8 i;
        u32 ip;
        u32 dg;
        u8 carry;
        u8 neg;
        u8 nonzero;
        u8 digits[20];
        double frac;

        if (canPrint == 0)
            {
            return;
            }
        if (roundAt < keep)
            {
            roundAt = keep;
            }
        if (roundAt > 18)
            {
            roundAt = 18;
            }

        neg = 0;
        if (v < 0.0d)
            {
            neg = 1;
            v = 0.0d - v;
            }

        ip = (u32)v;
        frac = v - (double)ip;

        // Extract roundAt+1 digits (index 0..roundAt); digits[roundAt] is the
        // round-off digit for a value rounded to `roundAt` decimal places.
        i = 0;
        while (i <= roundAt)
            {
            frac = frac * 10.0d;
            dg = (u32)frac;
            if (dg > 9)
                {
                dg = 9;
                }
            digits[i] = (u8)dg;
            frac = frac - (double)dg;
            i = i + 1;
            }

        // Round half-up at digits[roundAt], propagating the carry left (into ip).
        carry = 0;
        if (digits[roundAt] >= 5)
            {
            carry = 1;
            }
        i = roundAt;
        while (i > 0 && carry == 1)
            {
            i = i - 1;
            digits[i] = digits[i] + 1;
            if (digits[i] >= 10)
                {
                digits[i] = 0;
                carry = 1;
                }
            else
                {
                carry = 0;
                }
            }
        if (carry == 1)
            {
            ip = ip + 1;
            }

        // Emit '-' only if the ROUNDED value is non-zero (avoid "-0.000000").
        nonzero = 0;
        if (ip != 0)
            {
            nonzero = 1;
            }
        i = 0;
        while (i < keep)
            {
            if (digits[i] != 0)
                {
                nonzero = 1;
                }
            i = i + 1;
            }
        if (neg == 1 && nonzero == 1)
            {
            putChar((u8)$2D);
            }

        print(ip);
        putChar((u8)$2E); // '.'
        i = 0;
        while (i < keep)
            {
            putChar((u8)($30 + digits[i]));
            i = i + 1;
            }
        }

    static void print(float f) XTC_CLOAKED
        {
        printFpDec((double)f, 6, 6); // bare %f → round at 6dp
        }

    // ── print(float, u8 precision) — `%.Nf` ──────────────────────────
    // Prints `precision` digits past the decimal point, rounded at the
    // next one. `precision == 0` is the bare %f (6dp) form, which the
    // no-`.N` printf call site reaches with `prec` still zero.
    static void print(float f, u8 precision) XTC_CLOAKED
        {
        // bare %f
        if (precision == 0)
            {
            printFpDec((double)f, 6, 6);
            }
        // %.Nf: round N+1, keep N
        else
            {
            printFpDec((double)f, precision, precision + 1);
            }
        }

    // ── print(double) ─ MECH digit extraction, bare %lf ──────────────
    static void print(double d) XTC_CLOAKED
        {
        printFpDec(d, 10, 10); // bare %lf → round at 10dp
        }

    // ── print(double, u8 precision) — `%.Nlf` ────────────────────────
    // As print(float, u8); `precision == 0` is the bare %lf (10dp) form.
    static void print(double d, u8 precision) XTC_CLOAKED
        {
        // bare %lf
        if (precision == 0)
            {
            printFpDec(d, 10, 10);
            }
        // %.Nlf: round N+1, keep N
        else
            {
            printFpDec(d, precision, precision + 1);
            }
        }

    // ── Set cursor to (x, y) ─────────────────────────────────────────

    static void setCursor(u8 x, u8 y) XTC_CLOAKED
        {
        u16 offset;
        offset = y;
        offset = offset * cols;
        offset = offset + x;
        screenPtr = screenBase + offset;
        }

    // (Earlier revisions shipped a hand-written pullU8 / pullU16 /
    // pullU32 / pullFloat / pullDouble / pullString family here that
    // walked a class-ivar argPtr through the vararg buffer at $04B2.
    // That's exactly what the compiler's `va_arg_*` intrinsics now
    // do, so printf below uses the public API directly and the
    // helpers are gone.)

    // ── Struct/class printing ────────────────────────────────────────
    // The caller (printf's `%@` branch) has already deposited the
    // struct's data pointer into psDp and the descriptor pointer
    // into psDesc via two va_arg_u16 reads, so printStruct just
    // walks the descriptor. Descriptor format:
    //   byte 0: field count
    //   per field: type(1) size(1)
    //     type: 0=u8, 2=u16, 3=i16, 4=u32, 5=i32
    //     type 8 = nested struct (followed by 2-byte descriptor pointer)

    static void printStruct(void) XTC_CLOAKED
        {
        // psDp / psDesc / psFieldCount / psIdx are class ivars (see
        // the declarations near the top of the class) so they survive
        // the nested putChar / print() calls inside the loop. For
        // structs that contain other structs we maintain a small
        // save stack of 6-byte (psDp lo, psDp hi, psDesc lo,
        // psDesc hi, psFieldCount, psIdx) frames. psDp IS saved
        // here — nested-class (type-9) walks switch psDp to the
        // child's heap block and need to restore it on pop.
        //
        // Frame storage is hardware stack on cloak-capable targets
        // (xe-family) and the xtc software stack elsewhere. The
        // hw-stack form is mandatory inside :cloaked — PORTB=$30
        // unmaps the bank-0 window where the xtc stack lives on
        // canonical xe — and the 256-byte cap easily handles
        // realistic struct nesting (40+ levels). The xtc-stack form
        // has no fixed depth limit but isn't usable while cloaked.
        u8 fieldType;
        u8 fieldSize;
        u8 lo;
        u8 hi;
        u16 fieldVal;
        u8 depth;

        // psDp and psDesc are pre-loaded by the printf `%@` branch.
        putChar($28);

        psFieldCount = *psDesc;
        psDesc = psDesc + 1;
        psIdx = 0;
        depth = 0;

        while (1)
            {
            if (psIdx >= psFieldCount)
                {
                putChar($29);
                if (depth == 0)
                    {
                    return;
                    }
                // Pop a 6-byte frame into psIdx, psFieldCount,
                // psDesc-hi, psDesc-lo, psDp-hi, psDp-lo (in reverse
                // push order). psDp is always restored, so both
                // type-8 (inline struct, whose child walked the
                // inline bytes) and type-9 (class pointer, whose
                // child walked an entirely different heap block)
                // land back on the parent's next-field position.
                //
                // Where the save stack lives (XTC_LIB_HWSTACK):
                //  • cloak-capable targets — PORTB=$30 unmaps the
                //    bank-0 window where the xtc software stack lives
                //    on canonical xe, so any (XTC_SP_LO),Y access during
                //    a cloaked walk would corrupt the cloaked image;
                //  • xt — has no XTC_SP at all (its 4 KB hidden stack is
                //    the only stack the libs need).
                // Both push the 6-byte frames on the CPU hardware stack;
                // xt's 4 KB depth (and xe's aliased 256 bytes) handles
                // realistic nesting comfortably. Flat xl alone keeps the
                // xtc software stack, which has no fixed depth limit.
                asm
                {
#if XTC_LIB_HWSTACK
                    PLA : STA __sdata_Stdio+14    ; psIdx
                    PLA : STA __sdata_Stdio+13    ; psFieldCount
                    PLA : STA __sdata_Stdio+12    ; psDesc hi
                    PLA : STA __sdata_Stdio+11    ; psDesc lo
                    PLA : STA __sdata_Stdio+10    ; psDp hi
                    PLA : STA __sdata_Stdio+9     ; psDp lo
#else
                    LDY #$00
                    DEC XTC_SP_LO : BCS .pop_a : DEC XTC_SP_HI
                .pop_a:
                    LDA (XTC_SP_LO),Y : STA __sdata_Stdio+14    ; psIdx
                    DEC XTC_SP_LO : BCS .pop_b : DEC XTC_SP_HI
                .pop_b:
                    LDA (XTC_SP_LO),Y : STA __sdata_Stdio+13    ; psFieldCount
                    DEC XTC_SP_LO : BCS .pop_c : DEC XTC_SP_HI
                .pop_c:
                    LDA (XTC_SP_LO),Y : STA __sdata_Stdio+12    ; psDesc hi
                    DEC XTC_SP_LO : BCS .pop_d : DEC XTC_SP_HI
                .pop_d:
                    LDA (XTC_SP_LO),Y : STA __sdata_Stdio+11    ; psDesc lo
                    DEC XTC_SP_LO : BCS .pop_e : DEC XTC_SP_HI
                .pop_e:
                    LDA (XTC_SP_LO),Y : STA __sdata_Stdio+10    ; psDp hi
                    DEC XTC_SP_LO : BCS .pop_f : DEC XTC_SP_HI
                .pop_f:
                    LDA (XTC_SP_LO),Y : STA __sdata_Stdio+9    ; psDp lo
#endif
                }
                depth = depth - 1;
                continue;
                }

            if (psIdx > 0)
                {
                putChar($2C);
                putChar($20);
                }

            fieldType = *psDesc;
            psDesc = psDesc + 1;
            fieldSize = *psDesc;
            psDesc = psDesc + 1;

            if (fieldType == 0)
                {
                print((u16)*psDp);
                psDp = psDp + 1;
                }
            else if (fieldType == 2)
                {
                lo = *psDp;
                psDp = psDp + 1;
                hi = *psDp;
                psDp = psDp + 1;
                fieldVal = hi;
                fieldVal = (fieldVal << 8) | lo;
                print(fieldVal);
                }
            else if (fieldType == 3)
                {
                lo = *psDp;
                psDp = psDp + 1;
                hi = *psDp;
                psDp = psDp + 1;
                fieldVal = hi;
                fieldVal = (fieldVal << 8) | lo;
                print((i16)fieldVal);
                }
            else if (fieldType == 8)
                {
                // Nested inline struct. Stash the *post-struct*
                // psDp in psSaveDp, push the parent frame with that
                // post-struct value as the saved psDp (so the pop
                // lands on the parent's next field), then rewind
                // psDp back to the start of the struct's inline
                // bytes so the child walk consumes them.
                lo = *psDesc;
                psDesc = psDesc + 1;
                hi = *psDesc;
                psDesc = psDesc + 1;
                psIdx = psIdx + 1;
                psSaveDp = psDp;
                psDp = psDp + fieldSize;
                asm
                {
#if XTC_LIB_HWSTACK
                    LDA __sdata_Stdio+9  : PHA    ; psDp lo (post-struct)
                    LDA __sdata_Stdio+10 : PHA    ; psDp hi
                    LDA __sdata_Stdio+11 : PHA    ; psDesc lo
                    LDA __sdata_Stdio+12 : PHA    ; psDesc hi
                    LDA __sdata_Stdio+13 : PHA    ; psFieldCount
                    LDA __sdata_Stdio+14 : PHA    ; psIdx
#else
                    LDY #$00
                    LDA __sdata_Stdio+9 : STA (XTC_SP_LO),Y    ; psDp lo (post-struct)
                    INC XTC_SP_LO : BNE .push8_a : INC XTC_SP_HI
                .push8_a:
                    LDA __sdata_Stdio+10 : STA (XTC_SP_LO),Y    ; psDp hi
                    INC XTC_SP_LO : BNE .push8_b : INC XTC_SP_HI
                .push8_b:
                    LDA __sdata_Stdio+11 : STA (XTC_SP_LO),Y    ; psDesc lo
                    INC XTC_SP_LO : BNE .push8_c : INC XTC_SP_HI
                .push8_c:
                    LDA __sdata_Stdio+12 : STA (XTC_SP_LO),Y    ; psDesc hi
                    INC XTC_SP_LO : BNE .push8_d : INC XTC_SP_HI
                .push8_d:
                    LDA __sdata_Stdio+13 : STA (XTC_SP_LO),Y    ; psFieldCount
                    INC XTC_SP_LO : BNE .push8_e : INC XTC_SP_HI
                .push8_e:
                    LDA __sdata_Stdio+14 : STA (XTC_SP_LO),Y    ; psIdx
                    INC XTC_SP_LO : BNE .push8_f : INC XTC_SP_HI
                .push8_f:
#endif
                }
                depth = depth + 1;
                psDp = psSaveDp;
                psDesc = (main : u8*)((hi << 8) | lo);
                psFieldCount = *psDesc;
                psDesc = psDesc + 1;
                psIdx = 0;
                putChar($28);
                continue;
                }
            else if (fieldType == 9)
                {
                // Nested class: the parent's data bytes at psDp hold
                // a 2-byte heap pointer. Save the post-pointer psDp
                // in the pushed frame, read the heap pointer into
                // psSaveDp, then switch psDp to that heap block for
                // the child walk.
                u8 dpLo;
                u8 dpHi;
                dpLo = *psDp;
                psDp = psDp + 1;
                dpHi = *psDp;
                psDp = psDp + 1;
                lo = *psDesc;
                psDesc = psDesc + 1;
                hi = *psDesc;
                psDesc = psDesc + 1;
                psIdx = psIdx + 1;
                asm
                {
#if XTC_LIB_HWSTACK
                    LDA __sdata_Stdio+9  : PHA    ; psDp lo (post-pointer)
                    LDA __sdata_Stdio+10 : PHA    ; psDp hi
                    LDA __sdata_Stdio+11 : PHA    ; psDesc lo
                    LDA __sdata_Stdio+12 : PHA    ; psDesc hi
                    LDA __sdata_Stdio+13 : PHA    ; psFieldCount
                    LDA __sdata_Stdio+14 : PHA    ; psIdx
#else
                    LDY #$00
                    LDA __sdata_Stdio+9 : STA (XTC_SP_LO),Y    ; psDp lo (post-pointer)
                    INC XTC_SP_LO : BNE .push9_a : INC XTC_SP_HI
                .push9_a:
                    LDA __sdata_Stdio+10 : STA (XTC_SP_LO),Y    ; psDp hi
                    INC XTC_SP_LO : BNE .push9_b : INC XTC_SP_HI
                .push9_b:
                    LDA __sdata_Stdio+11 : STA (XTC_SP_LO),Y    ; psDesc lo
                    INC XTC_SP_LO : BNE .push9_c : INC XTC_SP_HI
                .push9_c:
                    LDA __sdata_Stdio+12 : STA (XTC_SP_LO),Y    ; psDesc hi
                    INC XTC_SP_LO : BNE .push9_d : INC XTC_SP_HI
                .push9_d:
                    LDA __sdata_Stdio+13 : STA (XTC_SP_LO),Y    ; psFieldCount
                    INC XTC_SP_LO : BNE .push9_e : INC XTC_SP_HI
                .push9_e:
                    LDA __sdata_Stdio+14 : STA (XTC_SP_LO),Y    ; psIdx
                    INC XTC_SP_LO : BNE .push9_f : INC XTC_SP_HI
                .push9_f:
#endif
                }
                depth = depth + 1;
                psSaveDp = (main : u8*)((dpHi << 8) | dpLo);
                psDp = psSaveDp;
                psDesc = (main : u8*)((hi << 8) | lo);
                psFieldCount = *psDesc;
                psDesc = psDesc + 1;
                psIdx = 0;
                putChar($28);
                continue;
                }
            else
                {
                psDp = psDp + fieldSize;
                putChar($3F);
                }

            psIdx = psIdx + 1;
            }
        }

    // ── printf — main formatted output method ────────────────────────

    // printf and printfAt deliberately keep main-RAM placement on
    // every target — same shape as the retired cloaked-variant
    // Stdio.xc did. Marking the varargs entry `:cloaked` opens a
    // sharp edge: when the caller is itself a numbered-bank-packed
    // function, the inline cloaked-bracket would unmap the caller's
    // bank mid-call, and the va-arg-pack-staged buffer access
    // afterwards mis-resolves through the wrong window. Leaving
    // these in main RAM costs ~150 bytes of main-RAM real estate
    // per program but keeps the dispatch trivially correct from any
    // caller (banked or not). The print(...) / putChar etc. callees
    // *are* cloaked, so the heavy formatting still moves out of
    // main RAM.
    static void printf(string fmt, ...)
        {
        u8 ch;
        u8 spec;
        u8 prec; // %.Nf precision (default 6 / 10), set per '%' below.
        u8 ap;

        if (canPrint == 0)
            {
            return;
            }

        // Walk the vararg buffer via the language's own va_*
        // intrinsics. Each va_arg_<type> reads at the current cursor
        // offset and advances by the type's width; we then dispatch
        // to the single overloaded print() that matches the pulled
        // value's type.
        va_start(ap);

        ch = *fmt;
        while (ch != 0)
            {
            if (ch == $25)
                {
                fmt = fmt + 1;
                spec = *fmt;

                // Optional .precision before the type char. Stores in
                // `prec`; the per-type branches below consult it on %f
                // / %lf. Default is 6 dp for %f and 10 dp for %lf when
                // no `.N` was supplied.
                // Flags and a field width are CONSUMED here but not APPLIED on this
                // target. Parsing them is the half that matters: printf used to fall
                // through `%10s` as unknown, emit "0s" as literal text and consume NO
                // argument, so every following argument shifted and %d printed a
                // pointer's low half. Padding is deliberately omitted: printf sits
                // within a few bytes of the 119-byte SP-frame budget (STACK-ABI §6.1)
                // and the locals it needs pushed the library to 123 and it stopped
                // compiling. A field width on a 40-column screen is the least
                // valuable half; the other five targets pad in full.
                while (spec == $2D || (spec >= $30 && spec <= $39))
                    {
                    fmt = fmt + 1;
                    spec = *fmt;
                    }
                prec = 0;
                if (spec == $2E) // '.'
                    {
                    fmt = fmt + 1;
                    spec = *fmt;
                    while (spec >= $30 && spec <= $39)
                        {
                        prec = prec * 10 + (spec - $30);
                        fmt = fmt + 1;
                        spec = *fmt;
                        }
                    }

                if (spec == $25)
                    {
                    putChar($25);
                    }
                else if (spec == $64)
                    {
                    // %d — signed 16-bit
                    print(va_arg_i16(ap));
                    }
                else if (spec == $75)
                    {
                    // %u — unsigned 16-bit
                    print(va_arg_u16(ap));
                    }
                else if (spec == $78)
                    {
                    // %x — unsigned 16-bit hex (4 digits)
                    printHex(va_arg_u16(ap));
                    }
                else if (spec == $6C)
                    {
                    // %l — 32-bit prefix
                    fmt = fmt + 1;
                    spec = *fmt;
                    // terminator after bare %l
                    if (spec == $00)
                        {
                        }
                    else if (spec == $6C)
                        {
                        // %ll — 64-bit prefix
                        fmt = fmt + 1;
                        spec = *fmt;
                        // %lld
                        if (spec == $64)
                            {
                            print(va_arg_i64(ap));
                            }
                        // %llu
                        else if (spec == $75)
                            {
                            print(va_arg_u64(ap));
                            }
                        }
                    else if (spec == $64)
                        {
                        print(va_arg_i32(ap));
                        }
                    else if (spec == $75)
                        {
                        print(va_arg_u32(ap));
                        }
                    else if (spec == $78)
                        {
                        printHex(va_arg_u32(ap));
                        }
                    else if (spec == $66)
                        {
                        // %lf — double. Pass
                        // va_arg_double's result straight through —
                        // capturing to a local would bump printf's
                        // ZP high-water mark by 8 bytes, and
                        // reserveUpToHighWater permanently squeezes
                        // every subsequent free function's local
                        // budget, forcing user floats and structs
                        // into heap-allocated spill slots.
                        print(va_arg_double(ap), prec);
                        }
                    }
                else if (spec == $63)
                    {
                    // %c — character
                    putChar(va_arg_u8(ap));
                    }
                else if (spec == $73)
                    {
                    // %s — string
                    print(va_arg_string(ap));
                    }
                else if (spec == $66)
                    {
                    // %f — float (see the %lf comment above for the
                    // reason we don't capture to a local). `prec` carries
                    // the optional `.N` modifier; 0 falls through to the
                    // historic 6dp default inside print(float, prec).
                    print(va_arg_float(ap), prec);
                    }
#if HAS_ATFMT
                else if (spec == $40)
                    {
                    // %@ — class instance via virtual `description()`
                    // dispatch. Object root declares
                    // `String* description(void)`; concrete classes
                    // override through the Hashable/Comparable vtable
                    // they all inherit. The returned String is printed
                    // through its c-string. `va_arg_ptr` so the full
                    // pointer width is pulled from the slot (xt6502
                    // 3-byte, arm64 8-byte; `va_arg_u16` would
                    // truncate on arm64). Struct support (which would
                    // walk a descriptor through printStruct) is a
                    // follow-up — psDp/psDesc/psFieldCount/psIdx and
                    // printStruct itself stay live for that.
                    Object* obj = (Object*)va_arg_ptr(ap);
                    print(obj.description());
                    }
#endif
                }
            else
                {
                putChar(ch);
                }

            fmt = fmt + 1;
            ch = *fmt;
            }

        va_end(ap);
        }

    // ── printfAt — positional formatted output ───────────────────────
    // Sets the cursor to (x, y) on the current screen, then prints.

    // See the printf() comment above — same reason for keeping
    // printfAt() in main RAM regardless of XTC_HAS_CLOAKED.
    static void printfAt(u8 x, u8 y, string fmt, ...)
        {
        setCursor(x, y);
        printf(fmt);
        }
    }
