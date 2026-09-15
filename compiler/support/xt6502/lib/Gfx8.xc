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

// Gfx8.xc - GR.8 (320x192 1bpp) primitives for the Gfx master class.
//
// Memory layout:
//   - Screen RAM is 320*192/8 = 7680 bytes at sbase.
//   - Each row is 40 bytes (320 px / 8 bits per byte).
//   - Pixel at (x, y) lives in byte sbase + yRowOffset[y] + (x>>3),
//     bit position $80 >> (x & 7) (high bit = leftmost pixel).
//
// Branchless plot: a 16-entry mask pair lets `plot` set or clear
// a bit without a conditional jump. Two halves indexed by colour:
//   andTable[c*8 + i]:  c=0 → clrMask[i], c=1 → $FF (no-op AND)
//   orTable[c*8 + i]:   c=0 → $00 (no-op OR), c=1 → setMask[i]
// Per-pixel cost in the hot loop is ≈18 instructions (assuming
// the line/rect callers inline this body).
//
// Tables:
//   - _gfx8_yLo[192], _gfx8_yHi[192]: y*40 split into low/high
//     bytes. Computed at first init() rather than baked into the
//     XEX so we save 384 bytes of binary at the cost of a ~3 ms
//     boot-time loop.
//   - _gfx8_andTable[16], _gfx8_orTable[16]: branchless bit
//     masks (see above).
//   - _gfx8_setMask[8]: standalone for getPixel's read-side.

#import "Stdio.xc"
#import "Gfx.xc"

u8 _gfx8_yLo[192];
u8 _gfx8_yHi[192];

// GR.8 display list (mode F = $0F): 24 lines of top-margin BLANKs,
// then 96 lines of mode F starting at $8100, then 96 more lines
// of mode F starting at $9000, then JVB back to the start.
//
// First LMS at $8100 instead of $8000: the screen RAM is then
// contiguous from $8100 through $9EFF (7680 bytes, no gap).
// ANTIC's 4 KB fetch boundary at $9000 still forces the second
// LMS - but with the first half ending at $8FFF and the second
// half starting at $9000, there's no unused gap between them.
// Drawing routines can use plain `sbase + y*40` byte addressing
// and clear() can write a single contiguous run.
//
// Layout (202 bytes used, 1 padding):
//   3x $70    24 blank scanlines (top margin)
//   $4F + word  LMS mode-F + screen address $8100
//   95x $0F   95 more mode-F lines (= 96 total this LMS section)
//   $4F + word  LMS mode-F + second-half $9000
//   95x $0F   95 more (= 96 total = 192 lines screen height)
//   $41 + word  JVB back to _gfx8_dlist
u8 _gfx8_dlist[203] = {
    $70, $70, $70,
    $4F, $00, $81,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F,
    $4F, $00, $90,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F, $0F,
    $0F, $0F, $0F, $0F, $0F,
    $41, $00, $00};
// JVB target ($00, $00 placeholder above) is patched on every
// setupNative() call to point back at the start of _gfx8_dlist
// - the literal initializer can't reference its own address.
// The patch is two byte stores; re-running is harmless.
u8 _gfx8_setMask[8] = {$80, $40, $20, $10, $08, $04, $02, $01};
u8 _gfx8_andTable[16] = {
    $7F, $BF, $DF, $EF, $F7, $FB, $FD, $FE,
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF};
u8 _gfx8_orTable[16] = {
    $00, $00, $00, $00, $00, $00, $00, $00,
    $80, $40, $20, $10, $08, $04, $02, $01};
// hline range-mask tables for the bulk-byte fast path.
// Indexed by bit-within-byte (lo or hi end of the line):
//
//   _gfx8_hLeftSet[bitLo]  : bits bitLo..7 (rightward of bitLo) set
//                            -> ORA mask for the leftmost byte of
//                               a multi-byte hline when pen = 1.
//   _gfx8_hLeftClr[bitLo]  : NOT _gfx8_hLeftSet[bitLo].
//                            -> ANDA mask for pen = 0.
//   _gfx8_hRightSet[bitHi] : bits 0..bitHi (leftward of bitHi) set
//                            -> ORA mask for the rightmost byte
//                               when pen = 1.
//   _gfx8_hRightClr[bitHi] : NOT _gfx8_hRightSet[bitHi].
//                            -> ANDA mask for pen = 0.
//
// Single-byte case (byteLo == byteHi): combine via
//   pen = 1: ORA hLeftSet[bitLo] AND hRightSet[bitHi]
//   pen = 0: AND hLeftClr[bitLo] OR  hRightClr[bitHi]
u8 _gfx8_hLeftSet[8] = {$FF, $7F, $3F, $1F, $0F, $07, $03, $01};
u8 _gfx8_hLeftClr[8] = {$00, $80, $C0, $E0, $F0, $F8, $FC, $FE};
u8 _gfx8_hRightSet[8] = {$80, $C0, $E0, $F0, $F8, $FC, $FE, $FF};
u8 _gfx8_hRightClr[8] = {$7F, $3F, $1F, $0F, $07, $03, $01, $00};
u8 _gfx8_ready = 0;

// floodFill seed-queue ring buffer. 256 entries, (u16 x, u8 y) per
// entry = 3 bytes/entry, 768 bytes total. head and tail are u8 so
// the modulo-256 wrap is implicit; count is a u16 because it
// reaches exactly 256 when the buffer is full and 0 when empty.
// Frontier is dropped silently on overflow — floodFill returns
// false in that case so callers can re-seed an unfilled region.
//
// Buffers are heap-allocated lazily on the first floodFill call
// rather than declared as static globals, so programs that never
// call floodFill don't pay for the 768 bytes in their binary.
// Allocations leak (no delete on Gfx8 destruction) — acceptable
// for typical single-instance programs where the heap is reclaimed
// on program exit; revisit if a future Gfx8 destructor needs them.
//
// Implementation note: x is split into parallel u8 lo/hi arrays
// — every push/pop writes one byte at offset Y in each, which is
// trivially fast and never tripped on the dynamic-index u16-write
// codegen path that originally drove this layout choice (now
// fixed; the split form is kept for performance, not necessity).

void _gfx8_buildTables(void)
    {
    if (_gfx8_ready != 0)
        {
        return;
        }
    u16 acc = 0;
    u8 i = 0;
    while (i < 192)
        {
        _gfx8_yLo[i] = (u8)(acc & $FF);
        _gfx8_yHi[i] = (u8)(acc >> 8);
        acc = acc + 40;
        i = i + 1;
        }
    _gfx8_ready = 1;
    return;
    }

class Gfx8 : Gfx
    {
    // Zero-arg init: reads the screen base from SAVMSC ($58/$59)
    // - for OS-managed GR.8 after a Gfx.setMode(GFX_GR8) call.
    void init(void)
        {
        readFromOS();
        at.x = 0;
        at.y = 0;
        pen = 1;
        fillColor = 0;
        clearBytes = 7680;
        _width = 320;
        _height = 192;
        if (_gfx8_ready == 0)
            {
            _gfx8_buildTables();
            }
        return;
        }

    // Construct a split GR.8 / mode-2 layout: (192 - 8*n) lines
    // of GR.8 on top, `n` text rows at the bottom. SAVMSC and
    // DINDEX are set so Stdio.printf, on its first lazy-init,
    // picks up the text screen as 40-col text. Calling sequence:
    //
    //   Gfx8* g = new Gfx8(4);
    //   Stdio.printf("score: %u\n", score);
    //   g.plot(x, y);
    //
    // textRows must be 1..11 - the dual-LMS graphics layout
    // assumes there are at least 8 lines of GR.8 in the
    // second half, so n maxes out at 11 (gr8Lines = 104).
    // For full-screen GR.8 with no text, use setupNative()
    // after `new Gfx8()`.
    void init(u8 textRows)
        {
        sbase = $8100;
        // gr8Lines = 192 - 8*textRows; clearBytes = gr8Lines * 40.
        // For n=4 (typical): gr8Lines=160, clearBytes=6400. The
        // text region at sbase+gr8Lines*40 stays untouched by
        // clear().
        u16 gr8Lines = (u16)(192 - 8 * textRows);
        clearBytes = gr8Lines * 40;
        at.x = 0;
        at.y = 0;
        pen = 1;
        fillColor = 0;
        if (_gfx8_ready == 0)
            {
            _gfx8_buildTables();
            }

        u16 textBase = _buildSplitDL(textRows);
        u8 textBaseLo = (u8)(textBase & $FF);
        u8 textBaseHi = (u8)(textBase >> 8);
        u8 botLin = textRows;

        // Copy the just-built DL from the static scratch into $8000,
        // the 256-byte gap immediately before the GR.8 screen RAM
        // at $8100. $8000 is $400-aligned so ANTIC's DL fetcher
        // never trips the 1 KB-wrap quirk, and the screen-RAM
        // region is always main RAM that ANTIC can see regardless
        // of PORTB banking. _buildSplitDL already emitted a JVB
        // target of $8000, so the copied DL self-loops correctly
        // without needing a runtime patch.
        // 204 - 7*textRows ≤ 197, fits in u8.
        u8 dlBytes = (u8)(204 - 7 * textRows);
        asm
        {
            ; SEI brackets the copy so an IRQ or VBI can't clobber
            ; $B0-$B3 mid-loop (the OS FP routines and some IRQ
            ; handlers can land in $B0-$BF). Also disable display
            ; via DMACTL = $00 so ANTIC isn't fetching DL bytes
            ; while we're copying. STX (not STA) so peephole
            ; passes that consider only same-instruction-form
            ; matches don't merge it with the later STA $D400.
            SEI
            LDX #$00
            STX $D400             ; DMACTL = no display
            LDA #<_gfx8_dlist
            STA $B0
            LDA #>_gfx8_dlist
            STA $B1
            LDA #$00
            STA $B2
            LDA #$80
            STA $B3
            LDX dlBytes
            LDY #$00
        _gfx8_dl_copy:
            LDA ($B0),Y
            STA ($B2),Y
            INY
            DEX
            BNE _gfx8_dl_copy
        }

        asm
            {
            ;
            Point ANTIC + OS shadow at the $8000 DL.LDA #$00 STA $0230
                              STA $D402
                                  LDA #$80 STA $0231
                                      STA $D403;
            SAVMSC = textBase.Stdio reads this on first use;
            to find the text screen base;
            pointing it at our;
            mode - 2 region routes printf into our text rows.LDA textBaseLo
                       STA $58
                           LDA textBaseHi
                               STA $59;
            DINDEX = 0(Stdio treats this as 40 - col text; and walks 40 - byte rows from SAVMSC).LDA #$00 STA $57;
            BOTSCR = textRows(1 - based row count, matching; the Atari OS convention).Stdio reads this on;
            init to size its scroll region so it walks only;
            the active text strip and not the GR.8 region above.LDA botLin
                                              STA $02BF;
            CHACTL = $02(default character control).LDA #$02 STA $D401;
            Re - enable display.LDA #$22 STA $D400 CLI
            }
        return;
        }

    // Construct against an explicit heap-buffer screen base.
    // For tests use `new Gfx8(buf)` where buf is a `u8*` from
    // `new u8[7680]`. For OS-managed GR.8 use `new Gfx8()` then
    // `g.readFromOS()` after issuing the GRAPHICS 8 command.
    void init(u8* buf)
        {
        sbase = (u16)buf;
        // Capture the buffer's data bank (byte 2 of the 3-byte pointer)
        // so clear()/primitives can select it — `(u16)buf` above drops
        // it. 0 when buf is in main RAM. (private:docs/bugs/007)
        u8 bk;
        asm { LDA buf+2 : STA bk }
        sbank = bk;
        at.x = 0;
        at.y = 0;
        pen = 1;
        fillColor = 0;
        clearBytes = 7680;
        _width = 320;
        _height = 192;
        if (_gfx8_ready == 0)
            {
            _gfx8_buildTables();
            }
        return;
        }

    // Update the screen base post-construction (e.g. after a
    // GRAPHICS-N mode change relocates the screen).
    void setBase(u16 base)
        {
        sbase = base;
        return;
        }

    // Read screen base from SAVMSC ($58/$59), the OS's last-
    // issued GRAPHICS-N screen pointer. Caller is responsible
    // for ensuring the OS is currently in GR.8.
    void readFromOS(void)
        {
        u8 lo;
        u8 hi;
        asm
            {
            LDA $58
            STA lo
            LDA $59
            STA hi
            }
        sbase = (u16)lo | ((u16)hi << 8);
        return;
        }

    // Reconfigure the display list at _gfx8_dlist for a
    // split-screen layout: (192 - 8*n) GR.8 scanlines on top
    // followed by `n` mode-2 text rows at the bottom, with
    // the text RAM placed immediately after the GR.8 second
    // half. Caller supplies textRows in 1..11. Returns the
    // text-screen base for the caller to stash in SAVMSC.
    //
    // Layout (textRows = n):
    //   3x $70                top BLANK margin (24 scanlines)
    //   $4F + $00 $81         LMS to graphics first half ($8100)
    //   95x $0F               first half = 96 mode F lines,
    //                         covering $8100-$8FFF
    //   $4F + $00 $90         LMS to graphics second half ($9000)
    //   (96 - 8n - 1)x $0F    second half = (96 - 8n) mode F lines
    //   $42 + textBaseLo Hi   LMS + mode 2 → text screen
    //   (n - 1)x $02          remaining mode 2 lines
    //   $41 + dl-start        JVB
    //
    // First LMS at $8100 makes the GR.8 buffer contiguous: the
    // first half ends at $8FFF and the second half starts at
    // $9000 with no gap, so byte addressing is plain
    // sbase + y*40 across the whole 7680-byte run.
    //
    // textBase = $9000 + (96 - 8n) * 40 sits right after the
    // graphics second half and stays within the $9000-$9FFF
    // 4 KB block for all n in 1..11.
    u16 _buildSplitDL(u8 textRows)
        {
        u16 secondHalfRows = (u16)(96 - 8 * textRows);
        u16 textBase = $9000 + secondHalfRows * 40;
        u8 textBaseLo = (u8)(textBase & $FF);
        u8 textBaseHi = (u8)(textBase >> 8);

        u8 i = 0;
        // 3 BLANK rows for top margin (24 scanlines).
        _gfx8_dlist[i] = $70;
        i = i + 1;
        _gfx8_dlist[i] = $70;
        i = i + 1;
        _gfx8_dlist[i] = $70;
        i = i + 1;

        // First LMS to $8100, then 95 more mode F lines = 96 total.
        _gfx8_dlist[i] = $4F;
        i = i + 1;
        _gfx8_dlist[i] = $00;
        i = i + 1;
        _gfx8_dlist[i] = $81;
        i = i + 1;
        u8 j = 0;
        while (j < 95)
            {
            _gfx8_dlist[i] = $0F;
            i = i + 1;
            j = j + 1;
            }

        // Second LMS to $9000, then (secondHalfRows - 1) more
        // mode F lines.
        _gfx8_dlist[i] = $4F;
        i = i + 1;
        _gfx8_dlist[i] = $00;
        i = i + 1;
        _gfx8_dlist[i] = $90;
        i = i + 1;
        j = 1;
        while ((u16)j < secondHalfRows)
            {
            _gfx8_dlist[i] = $0F;
            i = i + 1;
            j = j + 1;
            }

        // Mode 2 LMS to text base, then (textRows - 1) more
        // mode 2 lines.
        _gfx8_dlist[i] = $42;
        i = i + 1;
        _gfx8_dlist[i] = textBaseLo;
        i = i + 1;
        _gfx8_dlist[i] = textBaseHi;
        i = i + 1;
        j = 1;
        while (j < textRows)
            {
            _gfx8_dlist[i] = $02;
            i = i + 1;
            j = j + 1;
            }

        // JVB ($41) + 2-byte target = $8000 (the live DL location
        // — see init(textRows)'s copy step). $8000 is $400-aligned
        // (so the DL never trips ANTIC's 1 KB wrap), it's main RAM
        // visible to ANTIC regardless of PORTB banking state, and
        // it sits in the 256-byte gap between the start of the
        // screen-RAM region and the first LMS target at $8100, so
        // it costs zero usable bytes to host the DL there.
        _gfx8_dlist[i] = $41;
        i = i + 1;
        _gfx8_dlist[i] = $00;
        i = i + 1;
        _gfx8_dlist[i] = $80;
        i = i + 1;

        return textBase;
        }

    // Set up GR.8 (320x192 1bpp) without going through the OS
    // GRAPHICS 8 pathway. CIO's S: open is racy under shadow
    // mode and on at least one OS revision leaves VVBLKI zeroed
    // mid-call, hanging the program. Doing it ourselves:
    //   - Place the screen at $8000-$9DFF (7680 bytes within
    //     the xe layout's declared screen region $8000-$9FFF).
    //   - Build a 96+96 dual-LMS display list at _gfx8_dlist
    //     so ANTIC fetches mode-F (= GR.8) data across the
    //     $9000 4K boundary without fault.
    //   - Point both SDLSTL/SDLSTH ($0230/$0231) and ANTIC's
    //     DLISTL/DLISTH ($D402/$D403) at the new display list,
    //     so the OS-VBI's shadow-copy stays in sync if it ever
    //     fires.
    //   - Update SAVMSC ($58/$59) so any subsequent
    //     readFromOS() sees the manual screen.
    //   - Enable display via DMACTL ($D400 = $22 = playfield
    //     normal width, no PMG, DLI off until set explicitly)
    //     and CHACTL ($D401 = $02 default).
    // Caller (sbase) is set in this method - no separate
    // setBase() / readFromOS() call needed.
    void setupNative(void)
        {
        sbase = $8100;
        clearBytes = 7680;
        _width = 320;
        _height = 192;
        if (_gfx8_ready == 0)
            {
            _gfx8_buildTables();
            }
        asm
        {
            SEI
            ; Copy the static full-screen DL from _gfx8_dlist into
            ; $8000 - the 256-byte gap before the screen RAM at
            ; $8100. $8000 is $400-aligned so ANTIC's DL fetcher
            ; never trips its 1 KB-wrap quirk regardless of where
            ; the linker placed the static scratch. The static DL
            ; is 202 bytes (3 BLANK + LMS + 95 + LMS + 95 + JVB);
            ; copy 203 to also drag along the JVB target padding.
            LDA #<_gfx8_dlist
            STA $B0
            LDA #>_gfx8_dlist
            STA $B1
            LDA #$00
            STA $B2
            LDA #$80
            STA $B3
            LDX #203
            LDY #$00
        _gfx8_native_copy:
            LDA ($B0),Y
            STA ($B2),Y
            INY
            DEX
            BNE _gfx8_native_copy
            ; Patch the JVB target in the $8000 copy back to itself.
            ; JVB opcode is at offset 199, target lo/hi at 200/201.
            LDA #$00
            STA $80C8             ; $8000 + 200 (JVB target lo)
            LDA #$80
            STA $80C9             ; $8000 + 201 (JVB target hi)

            ; Disable display while we reconfigure.
            LDA #$00
            STA $D400             ; DMACTL = no display
            ; Point ANTIC + OS shadow at the $8000 DL.
            LDA #$00
            STA $0230             ; SDLSTL
            STA $D402             ; DLISTL
            LDA #$80
            STA $0231             ; SDLSTH
            STA $D403             ; DLISTH
            ; SAVMSC = $8100 (so any readFromOS() sees the same
            ; base the DL's first LMS uses).
            LDA #$00
            STA $58
            LDA #$81
            STA $59
            ; CHACTL default + character base.
            LDA #$02
            STA $D401             ; CHACTL
            ; Re-enable display: playfield normal width, normal
            ; DMA, no PMG, instructions fetched.
            LDA #$22
            STA $D400             ; DMACTL
            CLI
        }
        return;
        }

    // Plot a single pixel using pen. Bounds-checks; off-
    // screen plots are no-ops.
    //
    // ZP layout: locals use names with a `_g8p_` prefix so the
    // compiler-allocated slots don't collide with a caller's
    // locals across an `inline:plot(...)` expansion. The row
    // pointer is in `_g8p_ptr` (16 bits); the color*8+bitIndex
    // table index is in `_g8p_idx`. Without uniqueness, hline's
    // `px` and plot's scratch landed in the same ZP byte, so
    // every inlined plot iteration corrupted the outer loop
    // counter - a 30-second hang on a 10-pixel hline that took
    // a single trace pass to diagnose.
    void plot(i16 x, i16 y)
        {
        if (x < 0)
            {
            return;
            }
        if (x >= 320)
            {
            return;
            }
        if (y < 0)
            {
            return;
            }
        if (y >= 192)
            {
            return;
            }
        u16 _g8p_ux = (u16)x;
        u8 _g8p_uy = (u8)y;
        u8 _g8p_c = pen;
        u16 _g8p_sb = sbase;
        register u16 _g8p_ptr;
        u8 _g8p_idx;
        u8 _g8p_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g8p_sbk
            STA __bank_data_reg
            LDY _g8p_uy
            CLC
            LDA _g8p_sb
            ADC _gfx8_yLo,Y
            STA _g8p_ptr
            LDA _g8p_sb+1
            ADC _gfx8_yHi,Y
            STA _g8p_ptr+1
            ; byte offset within row = x >> 3
            LDA _g8p_ux+1
            LSR A
            LDA _g8p_ux
            ROR A
            LSR A
            LSR A                    ; A = x>>3 (0..39)
            TAY
            ; index = (color & 1) * 8 + (x & 7)
            LDA _g8p_c
            AND #$01
            ASL A
            ASL A
            ASL A
            STA _g8p_idx
            LDA _g8p_ux
            AND #$07
            ORA _g8p_idx
            TAX
            LDA (_g8p_ptr),Y
            AND _gfx8_andTable,X
            ORA _gfx8_orTable,X
            STA (_g8p_ptr),Y
        }
        return;
        }

    // Read one pixel. Returns 0 (clear) or 1 (set). Off-screen
    // reads return 0. Locals use `_g8g_` prefix for ZP-slot
    // uniqueness across `inline:getPixel(...)` expansions, same
    // as plot's `_g8p_`.
    u8 getPixel(i16 x, i16 y)
        {
        if (x < 0)
            {
            return 0;
            }
        if (x >= 320)
            {
            return 0;
            }
        if (y < 0)
            {
            return 0;
            }
        if (y >= 192)
            {
            return 0;
            }
        u16 _g8g_ux = (u16)x;
        u8 _g8g_uy = (u8)y;
        u16 _g8g_sb = sbase;
        register u16 _g8g_ptr;
        u8 result;
        u8 _g8g_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g8g_sbk
            STA __bank_data_reg
            LDY _g8g_uy
            CLC
            LDA _g8g_sb
            ADC _gfx8_yLo,Y
            STA _g8g_ptr
            LDA _g8g_sb+1
            ADC _gfx8_yHi,Y
            STA _g8g_ptr+1
            LDA _g8g_ux+1
            LSR A
            LDA _g8g_ux
            ROR A
            LSR A
            LSR A
            TAY
            LDA _g8g_ux
            AND #$07
            TAX
            LDA (_g8g_ptr),Y
            AND _gfx8_setMask,X
            ; A is 0 or one of $80/$40/.../$01. Branchless
            ; coerce to 0/1: CPX with X=A sets C iff A >= 1;
            ; ADC #0 deposits C into A which started at 0.
            TAX
            LDA #$00
            CPX #$01
            ADC #$00
            STA result
        }
        return result;
        }

    // Horizontal line from (x0, y) to (x1, y) inclusive. Auto-
    // orders endpoints, clips to screen. Bulk-byte fast path:
    // split into left-partial / middle full-byte run / right-
    // partial, with mask-table reads driving the partials and
    // straight STA #$FF / #$00 driving the middle. Roughly 10x
    // faster than the previous inline:plot-per-pixel loop on a
    // full-width line, and effectively constant overhead for
    // very short lines (single-byte case is one read-modify-
    // write).
    void hline(i16 x0, i16 x1, i16 y)
        {
        if (y < 0)
            {
            return;
            }
        if (y >= 192)
            {
            return;
            }
        i16 lo;
        i16 hi;
        if (x0 <= x1)
            {
            lo = x0;
            hi = x1;
            }
        else
            {
            lo = x1;
            hi = x0;
            }
        if (hi < 0)
            {
            return;
            }
        if (lo >= 320)
            {
            return;
            }
        if (lo < 0)
            {
            lo = 0;
            }
        if (hi >= 320)
            {
            hi = 319;
            }

        u16 _g8h_lo = (u16)lo;
        u16 _g8h_hi = (u16)hi;
        u8 _g8h_y = (u8)y;
        u8 _g8h_p = pen;
        u16 _g8h_sb = sbase;
        register u16 _g8h_ptr;
        u8 _g8h_bL;  // byte index of leftmost pixel
        u8 _g8h_bH;  // byte index of rightmost pixel
        u8 _g8h_iL;  // bit index within byteLo (0..7)
        u8 _g8h_iH;  // bit index within byteHi (0..7)
        u8 _g8h_msk; // scratch mask byte
        u8 _g8h_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g8h_sbk
            STA __bank_data_reg
            ; byteLo = lo >> 3, bitLo = lo & 7.
            LDA _g8h_lo+1
            LSR A
            LDA _g8h_lo
            ROR A
            LSR A
            LSR A
            STA _g8h_bL
            LDA _g8h_lo
            AND #$07
            STA _g8h_iL
            ; byteHi = hi >> 3, bitHi = hi & 7.
            LDA _g8h_hi+1
            LSR A
            LDA _g8h_hi
            ROR A
            LSR A
            LSR A
            STA _g8h_bH
            LDA _g8h_hi
            AND #$07
            STA _g8h_iH
            ; ptr = sbase + yTable[y] (gap-aware, set by the
            ; current contiguous / split mode of the global
            ; y-row table).
            LDY _g8h_y
            CLC
            LDA _g8h_sb
            ADC _gfx8_yLo,Y
            STA _g8h_ptr
            LDA _g8h_sb+1
            ADC _gfx8_yHi,Y
            STA _g8h_ptr+1
            ; Branch on pen: pen=1 sets bits via OR with
            ; range-mask tables, pen=0 clears via AND with the
            ; complementary tables.
            LDA _g8h_p
            BEQ _g8h_clr
            ; ---- pen = 1, set bits ----
            ; Single-byte case: byteLo == byteHi.
            LDA _g8h_bL
            CMP _g8h_bH
            BNE _g8h_set_multi
            LDX _g8h_iL
            LDA _gfx8_hLeftSet,X
            LDX _g8h_iH
            AND _gfx8_hRightSet,X
            LDY _g8h_bL
            ORA (_g8h_ptr),Y
            STA (_g8h_ptr),Y
            JMP _g8h_done
        _g8h_set_multi:
            ; Left partial (byteLo): OR with hLeftSet[bitLo].
            LDX _g8h_iL
            LDY _g8h_bL
            LDA (_g8h_ptr),Y
            ORA _gfx8_hLeftSet,X
            STA (_g8h_ptr),Y
            ; Middle bytes (byteLo+1 .. byteHi-1): count-driven
            ; DEX/BNE loop. Pre-fix this used CPY/BCS + JMP back
            ; to the test, which costs ~3 extra cycles per byte
            ; vs the direct STA/INY/DEX/BNE shape borrowed from
            ; Elite's HLOIN. Count = bH - bL - 1; BEQ skips when
            ; the partials are adjacent (no middle bytes).
            INY
            LDA _g8h_bH
            SEC
            SBC _g8h_bL
            SEC
            SBC #$01
            TAX
            BEQ _g8h_set_right
            LDA #$FF
        _g8h_set_mid:
            STA (_g8h_ptr),Y
            INY
            DEX
            BNE _g8h_set_mid
        _g8h_set_right:
            ; Right partial (byteHi): OR with hRightSet[bitHi].
            LDX _g8h_iH
            LDA _gfx8_hRightSet,X
            LDY _g8h_bH
            ORA (_g8h_ptr),Y
            STA (_g8h_ptr),Y
            JMP _g8h_done
            ; ---- pen = 0, clear bits ----
        _g8h_clr:
            LDA _g8h_bL
            CMP _g8h_bH
            BNE _g8h_clr_multi
            ; Single byte: AND with NOT(leftSet AND rightSet)
            ; = leftClr[bitLo] OR rightClr[bitHi].
            LDX _g8h_iL
            LDA _gfx8_hLeftClr,X
            LDX _g8h_iH
            ORA _gfx8_hRightClr,X
            LDY _g8h_bL
            AND (_g8h_ptr),Y
            STA (_g8h_ptr),Y
            JMP _g8h_done
        _g8h_clr_multi:
            ; Left partial: AND with hLeftClr[bitLo].
            LDX _g8h_iL
            LDY _g8h_bL
            LDA (_g8h_ptr),Y
            AND _gfx8_hLeftClr,X
            STA (_g8h_ptr),Y
            ; Middle bytes: same count-driven shape as the
            ; pen=1 path, just storing $00.
            INY
            LDA _g8h_bH
            SEC
            SBC _g8h_bL
            SEC
            SBC #$01
            TAX
            BEQ _g8h_clr_right
            LDA #$00
        _g8h_clr_mid:
            STA (_g8h_ptr),Y
            INY
            DEX
            BNE _g8h_clr_mid
        _g8h_clr_right:
            ; Right partial: AND with hRightClr[bitHi].
            LDX _g8h_iH
            LDA _gfx8_hRightClr,X
            LDY _g8h_bH
            AND (_g8h_ptr),Y
            STA (_g8h_ptr),Y
        _g8h_done:
        }
        return;
        }

    // Bresenham line from (x0, y0) to (x1, y1) inclusive.
    //
    // Fast-path coverage: all eight octants (x-major and
    // y-major), pen ∈ {0, 1}, all four endpoints on-screen.
    // Axis-aligned (dy == 0 or dx == 0) lines short-circuit to
    // hline / vline up front for a 5-10x win; only slanted
    // lines reach the Bresenham machinery.
    //
    // x-major draws from both ends simultaneously: a forward
    // pointer walks (x0, y0) -> midpoint, a backward pointer
    // walks (x1, y1) -> midpoint. Bresenham is point-symmetric,
    // so one shared err state drives both ends — fwd applies
    // each step in the natural direction, bwd in the opposite.
    // Two pixels per iter halves the count check + err update
    // overhead. Odd-length lines get a final middle-pixel plot
    // after the loop.
    //
    // Direction-specific opcodes (CLC<->SEC, ADC<->SBC, BCC<->
    // BCS, INC<->DEC) are patched in via SMC at setup for both
    // fwd and bwd y-step blocks; the runtime sy branch is gone.
    // y-major uses single-end draw with phase-4 SMC for the
    // y-step direction (sx-step has asymmetric INC/DEC borrow
    // detection that doesn't unify cleanly under SMC).
    //
    // Partly-off-screen lines fall back to the per-pixel
    // Bresenham slow path.
    void line(i16 x0, i16 y0, i16 x1, i16 y1)
        {
        // |dx|, |dy| and step direction in each axis.
        i16 dx;
        i16 dy;
        i16 sx;
        i16 sy;
        if (x1 >= x0)
            {
            dx = x1 - x0;
            sx = 1;
            }
        else
            {
            dx = x0 - x1;
            sx = -1;
            }
        if (y1 >= y0)
            {
            dy = y1 - y0;
            sy = 1;
            }
        else
            {
            dy = y0 - y1;
            sy = -1;
            }

        // Axis-aligned dispatch: hline / vline beat the Bresenham
        // path by 5-10x for horizontal / vertical runs (8-pixel
        // bulk OR per byte vs per-pixel mask shift). Common case
        // for outlining boxes via lineTo, so worth special-casing.
        // The fast paths normalise endpoint order internally; we
        // pass them through unchanged.
        if (dy == 0)
            {
            hline(x0, x1, y0);
            return;
            }
        if (dx == 0)
            {
            vline(x0, y0, y1);
            return;
            }

        // Normalise to sx = +1 by swapping endpoints when the
        // line walks right-to-left. Swapping flips both
        // signs, so sy follows along - `(sx=-1, sy=+1)` becomes
        // `(sx=+1, sy=-1)` and is rendered backwards from the
        // original x1,y1. The line shape is identical because
        // Bresenham is symmetric across endpoint order.
        if (sx < 0)
            {
            i16 tmpx = x0;
            x0 = x1;
            x1 = tmpx;
            i16 tmpy = y0;
            y0 = y1;
            y1 = tmpy;
            sx = 1;
            sy = -sy;
            }

        // -- x-major fast path (4 octants) -------------------
        // After normalisation sx is always +1. sy is +1 or -1
        // and drives the y-step variant (ADC vs SBC). All four
        // endpoints must be on-screen so the inner loop can
        // skip per-pixel clipping. pen=0 / pen=1 each have
        // their own tight loop.
        if (dx >= dy &&
            x0 >= 0 && y0 >= 0 && x1 < 320 && y1 < 192)
            {
            register u16 _g8l_ptr; // forward ptr
            u8 _g8l_mask;
            register u16 _g8l_bptr; // backward ptr
            u8 _g8l_bmask;
            // Bresenham midpoint err init. The asm body has the
            // x-step + err += 2*dy BEFORE the y-step decision
            // (one update earlier than the standard textbook
            // order), so the err state at the decision point is
            // already shifted by +2*dy from the canonical Bresen-
            // ham value. Compensate by subtracting 2*dy from the
            // standard init `2*dy - dx - 1`, leaving us with
            // `-(dx + 1)`. Without this the y-step fires too
            // often for slopes > 0.5, and the line endpoint
            // overshoots cy by 1 - the user spotted this as a
            // thick stray diagonal in the fan stress-test where
            // the affected lines bunched onto the same off-by-
            // one row.
            i16 _g8l_err = -(dx + 1);
            i16 _g8l_dy2 = dy + dy;
            i16 _g8l_dx2 = dx + dx;
            // Half-count drives the both-ends iter count; parity
            // selects whether to plot a middle pixel afterward.
            u16 _g8l_count = (u16)dx + 1;
            u16 _g8l_halfCt = _g8l_count >> 1;
            u8 _g8l_cntLo = (u8)(_g8l_halfCt & $FF);
            u8 _g8l_cntHi = (u8)(_g8l_halfCt >> 8);
            u8 _g8l_parity = (u8)(_g8l_count & 1);
            u16 _g8l_sb = sbase;
            u16 _g8l_ux0 = (u16)x0;
            u8 _g8l_uy0 = (u8)y0;
            u16 _g8l_ux1 = (u16)x1;
            u8 _g8l_uy1 = (u8)y1;
            u8 _g8l_pen = pen;
            u8 _g8l_syNeg = (sy < 0) ? 1 : 0;

            u8 _g8l_sbk = sbank;
            asm
            {
                ; Select the screen buffer's data bank before the indirect
                ; access below (private:docs/bugs/007); lookup tables are unbanked.
                LDA _g8l_sbk
                STA __bank_data_reg
                ; -- Setup: fwd ptr, fwd mask --------------------
                LDY _g8l_uy0
                CLC
                LDA _g8l_sb
                ADC _gfx8_yLo,Y
                STA _g8l_ptr
                LDA _g8l_sb+1
                ADC _gfx8_yHi,Y
                STA _g8l_ptr+1
                LDA _g8l_ux0+1
                LSR A
                LDA _g8l_ux0
                ROR A
                LSR A
                LSR A
                CLC
                ADC _g8l_ptr
                STA _g8l_ptr
                LDA _g8l_ptr+1
                ADC #$00
                STA _g8l_ptr+1
                LDA _g8l_ux0
                AND #$07
                TAX
                LDA _gfx8_setMask,X
                STA _g8l_mask
                ; -- Setup: bwd ptr, bwd mask --------------------
                LDY _g8l_uy1
                CLC
                LDA _g8l_sb
                ADC _gfx8_yLo,Y
                STA _g8l_bptr
                LDA _g8l_sb+1
                ADC _gfx8_yHi,Y
                STA _g8l_bptr+1
                LDA _g8l_ux1+1
                LSR A
                LDA _g8l_ux1
                ROR A
                LSR A
                LSR A
                CLC
                ADC _g8l_bptr
                STA _g8l_bptr
                LDA _g8l_bptr+1
                ADC #$00
                STA _g8l_bptr+1
                LDA _g8l_ux1
                AND #$07
                TAX
                LDA _gfx8_setMask,X
                STA _g8l_bmask
                ; -- SMC patch: y-step direction ----------------
                ; Patches both fwd (sy direction) and bwd (-sy
                ; direction, opposite) y-step opcodes for both
                ; pen variants. Always-patch so back-to-back
                ; lines with different sy don't inherit stale
                ; opcodes. 16 STAs per call (~96 cycles).
                LDA _g8l_syNeg
                BNE _g8l_smc_neg
                ; sy=+1: fwd=CLC/ADC/BCC/INC, bwd=SEC/SBC/BCS/DEC
                LDA #$18
                STA _g8l_p_clc
                STA _g8l_p0_clc
                LDA #$69
                STA _g8l_p_adc
                STA _g8l_p0_adc
                LDA #$90
                STA _g8l_p_bcc
                STA _g8l_p0_bcc
                LDA #$E6
                STA _g8l_p_inc
                STA _g8l_p0_inc
                LDA #$38
                STA _g8l_b_sec
                STA _g8l_b0_sec
                LDA #$E9
                STA _g8l_b_sbc
                STA _g8l_b0_sbc
                LDA #$B0
                STA _g8l_b_bcs
                STA _g8l_b0_bcs
                LDA #$C6
                STA _g8l_b_dec
                STA _g8l_b0_dec
                JMP _g8l_smc_done
            _g8l_smc_neg:
                ; sy=-1: fwd=SEC/SBC/BCS/DEC, bwd=CLC/ADC/BCC/INC
                LDA #$38
                STA _g8l_p_clc
                STA _g8l_p0_clc
                LDA #$E9
                STA _g8l_p_adc
                STA _g8l_p0_adc
                LDA #$B0
                STA _g8l_p_bcc
                STA _g8l_p0_bcc
                LDA #$C6
                STA _g8l_p_inc
                STA _g8l_p0_inc
                LDA #$18
                STA _g8l_b_sec
                STA _g8l_b0_sec
                LDA #$69
                STA _g8l_b_sbc
                STA _g8l_b0_sbc
                LDA #$90
                STA _g8l_b_bcs
                STA _g8l_b0_bcs
                LDA #$E6
                STA _g8l_b_dec
                STA _g8l_b0_dec
            _g8l_smc_done:
                ; Skip main loop entirely if half-count is 0
                ; (count = 1 -> single pixel via parity tail).
                LDA _g8l_cntLo
                ORA _g8l_cntHi
                BEQ _g8l_tail
                LDA _g8l_pen
                BEQ _g8l_loop0
                ; -- pen=1 both-ends inner loop ----------------
            _g8l_loop:
                LDY #$00
                LDA _g8l_mask
                ORA (_g8l_ptr),Y
                STA (_g8l_ptr),Y
                LDA _g8l_bmask
                ORA (_g8l_bptr),Y
                STA (_g8l_bptr),Y
                LSR _g8l_mask
                BNE _g8l_x_done
                LDA #$80
                STA _g8l_mask
                INC _g8l_ptr
                BNE _g8l_x_done
                INC _g8l_ptr+1
            _g8l_x_done:
                ASL _g8l_bmask
                BNE _g8l_bx_done
                LDA #$01
                STA _g8l_bmask
                LDA _g8l_bptr
                BNE _g8l_b_no_borrow
                DEC _g8l_bptr+1
            _g8l_b_no_borrow:
                DEC _g8l_bptr
            _g8l_bx_done:
                CLC
                LDA _g8l_err
                ADC _g8l_dy2
                STA _g8l_err
                LDA _g8l_err+1
                ADC _g8l_dy2+1
                STA _g8l_err+1
                BMI _g8l_no_y_step
            _g8l_p_clc:
                CLC                   ; <-> SEC
                LDA _g8l_ptr
            _g8l_p_adc:
                ADC #$28              ; <-> SBC #$28
                STA _g8l_ptr
            _g8l_p_bcc:
                BCC _g8l_fy_done      ; <-> BCS
            _g8l_p_inc:
                INC _g8l_ptr+1        ; <-> DEC
            _g8l_fy_done:
            _g8l_b_sec:
                SEC                   ; <-> CLC
                LDA _g8l_bptr
            _g8l_b_sbc:
                SBC #$28              ; <-> ADC #$28
                STA _g8l_bptr
            _g8l_b_bcs:
                BCS _g8l_by_done      ; <-> BCC
            _g8l_b_dec:
                DEC _g8l_bptr+1       ; <-> INC
            _g8l_by_done:
                SEC
                LDA _g8l_err
                SBC _g8l_dx2
                STA _g8l_err
                LDA _g8l_err+1
                SBC _g8l_dx2+1
                STA _g8l_err+1
            _g8l_no_y_step:
                LDA _g8l_cntLo
                BNE _g8l_cnt_lo_dec
                LDA _g8l_cntHi
                BEQ _g8l_tail
                DEC _g8l_cntHi
            _g8l_cnt_lo_dec:
                DEC _g8l_cntLo
                LDA _g8l_cntLo
                ORA _g8l_cntHi
                BNE _g8l_loop
                JMP _g8l_tail
                ; -- pen=0 both-ends inner loop ----------------
            _g8l_loop0:
                LDY #$00
                LDA _g8l_mask
                EOR #$FF
                AND (_g8l_ptr),Y
                STA (_g8l_ptr),Y
                LDA _g8l_bmask
                EOR #$FF
                AND (_g8l_bptr),Y
                STA (_g8l_bptr),Y
                LSR _g8l_mask
                BNE _g8l_x_done0
                LDA #$80
                STA _g8l_mask
                INC _g8l_ptr
                BNE _g8l_x_done0
                INC _g8l_ptr+1
            _g8l_x_done0:
                ASL _g8l_bmask
                BNE _g8l_bx_done0
                LDA #$01
                STA _g8l_bmask
                LDA _g8l_bptr
                BNE _g8l_b_no_borrow0
                DEC _g8l_bptr+1
            _g8l_b_no_borrow0:
                DEC _g8l_bptr
            _g8l_bx_done0:
                CLC
                LDA _g8l_err
                ADC _g8l_dy2
                STA _g8l_err
                LDA _g8l_err+1
                ADC _g8l_dy2+1
                STA _g8l_err+1
                BMI _g8l_no_y_step0
            _g8l_p0_clc:
                CLC                   ; <-> SEC
                LDA _g8l_ptr
            _g8l_p0_adc:
                ADC #$28              ; <-> SBC #$28
                STA _g8l_ptr
            _g8l_p0_bcc:
                BCC _g8l_fy_done0     ; <-> BCS
            _g8l_p0_inc:
                INC _g8l_ptr+1        ; <-> DEC
            _g8l_fy_done0:
            _g8l_b0_sec:
                SEC                   ; <-> CLC
                LDA _g8l_bptr
            _g8l_b0_sbc:
                SBC #$28              ; <-> ADC #$28
                STA _g8l_bptr
            _g8l_b0_bcs:
                BCS _g8l_by_done0     ; <-> BCC
            _g8l_b0_dec:
                DEC _g8l_bptr+1       ; <-> INC
            _g8l_by_done0:
                SEC
                LDA _g8l_err
                SBC _g8l_dx2
                STA _g8l_err
                LDA _g8l_err+1
                SBC _g8l_dx2+1
                STA _g8l_err+1
            _g8l_no_y_step0:
                LDA _g8l_cntLo
                BNE _g8l_cnt_lo_dec0
                LDA _g8l_cntHi
                BEQ _g8l_tail
                DEC _g8l_cntHi
            _g8l_cnt_lo_dec0:
                DEC _g8l_cntLo
                LDA _g8l_cntLo
                ORA _g8l_cntHi
                BNE _g8l_loop0
                ; fall through to _g8l_tail
                ; -- Tail: parity middle pixel ------------------
                ; Odd total counts leave one pixel unplotted at
                ; the meeting point. fwd_ptr / fwd_mask now
                ; point at exactly that pixel.
            _g8l_tail:
                LDA _g8l_parity
                BEQ _g8l_done
                LDY #$00
                LDA _g8l_pen
                BEQ _g8l_tail_pen0
                LDA _g8l_mask
                ORA (_g8l_ptr),Y
                STA (_g8l_ptr),Y
                JMP _g8l_done
            _g8l_tail_pen0:
                LDA _g8l_mask
                EOR #$FF
                AND (_g8l_ptr),Y
                STA (_g8l_ptr),Y
            _g8l_done:
            }
            return;
            }

        // -- y-major fast path (4 octants) -------------------
        // Mirror of the x-major block: y advances every
        // iteration, x only when err crosses 0. No endpoint
        // swap here - sx and sy keep their original signs and
        // drive parameterised step variants in the inner loop:
        //   y-step: ADC #40 (sy=+1) / SBC #40 (sy=-1)
        //   x-step: LSR mask + INC ptr (sx=+1) /
        //           ASL mask + DEC ptr (sx=-1)
        // The reordered loop body (plot ; y-step ; err += 2*dx ;
        // if err >= 0: x-step + err -= 2*dy) is one update
        // earlier than the textbook order, so the err init
        // compensates by subtracting an extra 2*dx, leaving
        // -(dy + 1) (the y-major analogue of the x-major
        // path's -(dx + 1)).
        if (dx < dy &&
            x0 >= 0 && y0 >= 0 && x1 >= 0 && y1 >= 0 &&
            x0 < 320 && x1 < 320 && y0 < 192 && y1 < 192)
            {
            register u16 _g8m_ptr;
            u8 _g8m_mask;
            i16 _g8m_err = -((i16)dy + 1);
            i16 _g8m_dx2 = dx + dx;
            i16 _g8m_dy2 = dy + dy;
            u16 _g8m_count = (u16)dy + 1;
            u8 _g8m_cntLo = (u8)(_g8m_count & $FF);
            u8 _g8m_cntHi = (u8)(_g8m_count >> 8);
            u16 _g8m_sb = sbase;
            u16 _g8m_ux0 = (u16)x0;
            u8 _g8m_uy0 = (u8)y0;
            u8 _g8m_pen = pen;
            u8 _g8m_sxNeg = (sx < 0) ? 1 : 0;
            u8 _g8m_syNeg = (sy < 0) ? 1 : 0;

            u8 _g8m_sbk = sbank;
            asm
            {
                ; Select the screen buffer's data bank before the indirect
                ; access below (private:docs/bugs/007); lookup tables are unbanked.
                LDA _g8m_sbk
                STA __bank_data_reg
                ; ptr = sbase + yTable[y0] + (x0 >> 3)
                LDY _g8m_uy0
                CLC
                LDA _g8m_sb
                ADC _gfx8_yLo,Y
                STA _g8m_ptr
                LDA _g8m_sb+1
                ADC _gfx8_yHi,Y
                STA _g8m_ptr+1
                LDA _g8m_ux0+1
                LSR A
                LDA _g8m_ux0
                ROR A
                LSR A
                LSR A
                CLC
                ADC _g8m_ptr
                STA _g8m_ptr
                LDA _g8m_ptr+1
                ADC #$00
                STA _g8m_ptr+1
                ; mask = setMask[x0 & 7]
                LDA _g8m_ux0
                AND #$07
                TAX
                LDA _gfx8_setMask,X
                STA _g8m_mask
                ; -- SMC patch: y-step direction (same as x-major) --
                ; y-step fires every iter in y-major, so cutting
                ; the runtime sy branch saves 4-5 cycles per pixel.
                ; sx-step is kept as a runtime branch because INC/
                ; DEC have asymmetric borrow-detection shapes.
                LDA _g8m_syNeg
                BNE _g8m_smc_neg
                LDA #$18              ; CLC
                STA _g8m_p_clc
                STA _g8m_p0_clc
                LDA #$69              ; ADC #imm
                STA _g8m_p_adc
                STA _g8m_p0_adc
                LDA #$90              ; BCC
                STA _g8m_p_bcc
                STA _g8m_p0_bcc
                LDA #$E6              ; INC zp
                STA _g8m_p_inc
                STA _g8m_p0_inc
                JMP _g8m_smc_done
            _g8m_smc_neg:
                LDA #$38              ; SEC
                STA _g8m_p_clc
                STA _g8m_p0_clc
                LDA #$E9              ; SBC #imm
                STA _g8m_p_adc
                STA _g8m_p0_adc
                LDA #$B0              ; BCS
                STA _g8m_p_bcc
                STA _g8m_p0_bcc
                LDA #$C6              ; DEC zp
                STA _g8m_p_inc
                STA _g8m_p0_inc
            _g8m_smc_done:
                ; pen branch
                LDA _g8m_pen
                BEQ _g8m_loop0
                ; ---- y-major pen=1 inner loop ----
            _g8m_loop:
                LDY #$00
                LDA _g8m_mask
                ORA (_g8m_ptr),Y
                STA (_g8m_ptr),Y
                ; y-step (every iter; opcodes patched by SMC)
            _g8m_p_clc:
                CLC                   ; <-> SEC
                LDA _g8m_ptr
            _g8m_p_adc:
                ADC #$28              ; <-> SBC #$28
                STA _g8m_ptr
            _g8m_p_bcc:
                BCC _g8m_y_done       ; <-> BCS
            _g8m_p_inc:
                INC _g8m_ptr+1        ; <-> DEC
            _g8m_y_done:
                ; err += 2*dx (16-bit)
                CLC
                LDA _g8m_err
                ADC _g8m_dx2
                STA _g8m_err
                LDA _g8m_err+1
                ADC _g8m_dx2+1
                STA _g8m_err+1
                BMI _g8m_no_x
                ; x-step (branch on sxNeg)
                LDA _g8m_sxNeg
                BNE _g8m_x_neg
                ; sx=+1: LSR mask + INC ptr on byte cross
                LSR _g8m_mask
                BNE _g8m_x_done
                LDA #$80
                STA _g8m_mask
                INC _g8m_ptr
                BNE _g8m_x_done
                INC _g8m_ptr+1
                JMP _g8m_x_done
            _g8m_x_neg:
                ; sx=-1: ASL mask + DEC ptr on byte cross
                ASL _g8m_mask
                BNE _g8m_x_done
                LDA #$01
                STA _g8m_mask
                LDA _g8m_ptr
                BNE _g8m_no_borrow
                DEC _g8m_ptr+1
            _g8m_no_borrow:
                DEC _g8m_ptr
            _g8m_x_done:
                ; err -= 2*dy
                SEC
                LDA _g8m_err
                SBC _g8m_dy2
                STA _g8m_err
                LDA _g8m_err+1
                SBC _g8m_dy2+1
                STA _g8m_err+1
            _g8m_no_x:
                ; 16-bit countdown
                LDA _g8m_cntLo
                BNE _g8m_cnt_dec
                LDA _g8m_cntHi
                BEQ _g8m_done
                DEC _g8m_cntHi
            _g8m_cnt_dec:
                DEC _g8m_cntLo
                LDA _g8m_cntLo
                ORA _g8m_cntHi
                BNE _g8m_loop
                JMP _g8m_done
                ; ---- y-major pen=0 inner loop ----
            _g8m_loop0:
                LDY #$00
                LDA _g8m_mask
                EOR #$FF
                AND (_g8m_ptr),Y
                STA (_g8m_ptr),Y
                ; y-step (SMC: opcodes patched at setup)
            _g8m_p0_clc:
                CLC                   ; <-> SEC
                LDA _g8m_ptr
            _g8m_p0_adc:
                ADC #$28              ; <-> SBC #$28
                STA _g8m_ptr
            _g8m_p0_bcc:
                BCC _g8m_y_done0      ; <-> BCS
            _g8m_p0_inc:
                INC _g8m_ptr+1        ; <-> DEC
            _g8m_y_done0:
                CLC
                LDA _g8m_err
                ADC _g8m_dx2
                STA _g8m_err
                LDA _g8m_err+1
                ADC _g8m_dx2+1
                STA _g8m_err+1
                BMI _g8m_no_x0
                LDA _g8m_sxNeg
                BNE _g8m_x_neg0
                LSR _g8m_mask
                BNE _g8m_x_done0
                LDA #$80
                STA _g8m_mask
                INC _g8m_ptr
                BNE _g8m_x_done0
                INC _g8m_ptr+1
                JMP _g8m_x_done0
            _g8m_x_neg0:
                ASL _g8m_mask
                BNE _g8m_x_done0
                LDA #$01
                STA _g8m_mask
                LDA _g8m_ptr
                BNE _g8m_no_borrow0
                DEC _g8m_ptr+1
            _g8m_no_borrow0:
                DEC _g8m_ptr
            _g8m_x_done0:
                SEC
                LDA _g8m_err
                SBC _g8m_dy2
                STA _g8m_err
                LDA _g8m_err+1
                SBC _g8m_dy2+1
                STA _g8m_err+1
            _g8m_no_x0:
                LDA _g8m_cntLo
                BNE _g8m_cnt_dec0
                LDA _g8m_cntHi
                BEQ _g8m_done
                DEC _g8m_cntHi
            _g8m_cnt_dec0:
                DEC _g8m_cntLo
                LDA _g8m_cntLo
                ORA _g8m_cntHi
                BNE _g8m_loop0
            _g8m_done:
            }
            return;
            }

        // -- Slow path: per-pixel Bresenham via inline:plot --
        // Handles every octant correctly; performance falls
        // back to ~150 cycles/pixel until the fast path is
        // extended.
        //
        i16 cx = x0;
        i16 cy = y0;

        // err init is `2*dy - dx - 1` (or `2*dx - dy - 1` for
        // y-major). The -1 shifts our `>= 0` y-step threshold
        // to match the standard Bresenham `> 0` placement,
        // otherwise the line takes one y-step too many and the
        // last pixel lands one row off the line endpoint -
        // visible as a slight thickening on lines whose slope
        // is close to a clean fraction (the fan stress-test
        // showed a stray diagonal where many shallow lines
        // converged on the same off-by-one row).
        if (dx >= dy)
            {
            // x-major: step in x every iteration, in y when
            // err crosses 0.
            i16 err = dy + dy - dx - 1;
            i16 i = 0;
            while (i <= dx)
                {
                inline : plot(cx, cy);
                if (err >= 0)
                    {
                    cy = cy + sy;
                    err = err - dx - dx;
                    }
                err = err + dy + dy;
                cx = cx + sx;
                i = i + 1;
                }
            }
        else
            {
            // y-major: roles of dx/dy swap.
            i16 err = dx + dx - dy - 1;
            i16 i = 0;
            while (i <= dy)
                {
                inline : plot(cx, cy);
                if (err >= 0)
                    {
                    cx = cx + sx;
                    err = err - dy - dy;
                    }
                err = err + dx + dx;
                cy = cy + sy;
                i = i + 1;
                }
            }
        return;
        }

    // Plot an 8x8 character glyph at pixel (x, y), top-left
    // corner of the cell. Reads the glyph from the OS character
    // ROM (or shadow-mode RAM copy at $2000), located via CHBAS
    // ($02F4) - so any custom font installed via CHBAS is
    // honoured automatically. ATASCII -> internal-screen-code
    // conversion follows the standard Atari mapping:
    //   $00-$1F  control / graphics  -> internal $40-$5F
    //   $20-$5F  space..underscore   -> internal $00-$3F
    //   $60-$7F  lowercase / tilde   -> internal $60-$7F
    // Bit 7 (inverse video) is currently stripped - every glyph
    // renders normal-polarity. pen-aware via inline:plot, so
    // setPen(0) erases instead of draws.
    //
    // Phase 1: 64 inline:plot calls per character. Subsequent
    // phases will fold byte-aligned x positions into 8 bulk-OR
    // writes per row and shifted x into a 2-byte mask path.

    // Plot an ASCII string starting at pixel (x, y), advancing
    // x by 8 pixels per character. No bounds check on x - glyphs
    // that would land off-screen on the right are clipped per-
    // pixel by inline:plot. Newline ($0A) advances y by 8 and
    // resets x; null terminator ($00) ends the string.

    // Cursor-based line draw: from the current `here` to (x, y),
    // then leave `here` at the new endpoint. Lets call sites
    // chain segments without spelling out the previous endpoint:
    //
    //     g.moveTo(10, 10);
    //     g.lineTo(50, 10);    // horizontal segment
    //     g.lineTo(50, 50);    // vertical segment
    //     g.lineTo(10, 50);    // closing edge
    //
    // Lives on Gfx8 (rather than Gfx) so the line() call lands on
    // Gfx8.line directly. The earlier "lineTo on the master Gfx
    // class plus an abstract Gfx.line() default" shape changed
    // the dispatch shape in a way that broke gfx8_split_text's
    // post-init Stdio writes - keep it concrete for now.
    void lineTo(i16 x, i16 y)
        {
        line(at.x, at.y, x, y);
        at.x = x;
        at.y = y;
        return;
        }

    // Point-taking lineTo: lets callers chain from a Point value
    // (e.g. an endpoint stored from a previous `currentPoint()`)
    // without unpacking into x / y locals.
    void lineTo(Point p)
        {
        line(at.x, at.y, p.x, p.y);
        at.x = p.x;
        at.y = p.y;
        return;
        }

    // Vertical line at column x from row y0 to row y1 inclusive.
    // Single ORA / ANDA per row - no Bresenham, no per-iter
    // sign / err checks; the byte address advances by 40 on each
    // step, the bit mask never changes, and the pen branch picks
    // a tight 6-instruction loop body. ~30 cycles per pixel vs
    // line's ~50-55 for the y-major fast path.
    //
    // x out of [0, 319] is a no-op; y0 / y1 outside [0, 191] are
    // clipped to that range (so a partly-off-screen vline still
    // draws the on-screen portion). y0 > y1 is normalised by
    // swap.
    void vline(i16 x, i16 y0, i16 y1)
        {
        if (x < 0 || x >= 320)
            {
            return;
            }
        // Clip y to screen.
        if (y0 < 0)
            {
            y0 = 0;
            }
        if (y1 < 0)
            {
            y1 = 0;
            }
        if (y0 >= 192)
            {
            y0 = 191;
            }
        if (y1 >= 192)
            {
            y1 = 191;
            }
        // Normalise y0 <= y1.
        if (y0 > y1)
            {
            i16 t = y0;
            y0 = y1;
            y1 = t;
            }

        register u16 _g8v_ptr;
        u8 _g8v_mask;
        u16 _g8v_count = (u16)(y1 - y0 + 1);
        u8 _g8v_cntLo = (u8)(_g8v_count & $FF);
        u8 _g8v_cntHi = (u8)(_g8v_count >> 8);
        u16 _g8v_sb = sbase;
        u16 _g8v_ux = (u16)x;
        u8 _g8v_uy0 = (u8)y0;
        u8 _g8v_pen = pen;

        u8 _g8v_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g8v_sbk
            STA __bank_data_reg
            ; ptr = sbase + yTable[y0] + (x >> 3)
            LDY _g8v_uy0
            CLC
            LDA _g8v_sb
            ADC _gfx8_yLo,Y
            STA _g8v_ptr
            LDA _g8v_sb+1
            ADC _gfx8_yHi,Y
            STA _g8v_ptr+1
            LDA _g8v_ux+1
            LSR A
            LDA _g8v_ux
            ROR A
            LSR A
            LSR A
            CLC
            ADC _g8v_ptr
            STA _g8v_ptr
            LDA _g8v_ptr+1
            ADC #$00
            STA _g8v_ptr+1
            ; mask = setMask[x & 7]
            LDA _g8v_ux
            AND #$07
            TAX
            LDA _gfx8_setMask,X
            STA _g8v_mask
            ; pen branch. pen=0 uses the inverted mask AND'd in.
            LDA _g8v_pen
            BEQ _g8v_loop0
            ; pen=1: ORA mask into (ptr),Y each iter; ptr += 40.
            LDY #$00
        _g8v_loop:
            LDA _g8v_mask
            ORA (_g8v_ptr),Y
            STA (_g8v_ptr),Y
            ; ptr += 40
            CLC
            LDA _g8v_ptr
            ADC #$28
            STA _g8v_ptr
            BCC _g8v_lo_done
            INC _g8v_ptr+1
        _g8v_lo_done:
            ; 16-bit countdown. Count starts at (y1-y0+1)
            ; (always >= 1). Decrement cntLo; on borrow, also
            ; decrement cntHi; exit when both are zero.
            LDA _g8v_cntLo
            BNE _g8v_dec
            LDA _g8v_cntHi
            BEQ _g8v_done
            DEC _g8v_cntHi
        _g8v_dec:
            DEC _g8v_cntLo
            LDA _g8v_cntLo
            ORA _g8v_cntHi
            BNE _g8v_loop
            JMP _g8v_done
        _g8v_loop0:
            ; pen=0: AND inverted mask into (ptr),Y. Stage the
            ; inverted mask once so each iter is just LDA mask;
            ; AND ptr,Y; STA ptr,Y; advance.
            LDA _g8v_mask
            EOR #$FF
            STA _g8v_mask
            LDY #$00
        _g8v_loop0_top:
            LDA _g8v_mask
            AND (_g8v_ptr),Y
            STA (_g8v_ptr),Y
            CLC
            LDA _g8v_ptr
            ADC #$28
            STA _g8v_ptr
            BCC _g8v_lo_done0
            INC _g8v_ptr+1
        _g8v_lo_done0:
            LDA _g8v_cntLo
            BNE _g8v_dec0
            LDA _g8v_cntHi
            BEQ _g8v_done
            DEC _g8v_cntHi
        _g8v_dec0:
            DEC _g8v_cntLo
            LDA _g8v_cntLo
            ORA _g8v_cntHi
            BNE _g8v_loop0_top
        _g8v_done:
        }
        return;
        }

    // Outline of an axis-aligned rectangle. Endpoints are
    // inclusive - `rect(0, 0, 9, 9)` lights the perimeter pixels
    // of the 10x10 square at the origin. Two hlines for the top
    // and bottom edges, two vlines for the left and right; the
    // four corner pixels are visited twice but that's a no-op for
    // pen=1 (OR with the same mask) and idempotent for pen=0
    // (AND with the same inverted mask).
    //
    // Caller is responsible for x0 <= x1 and y0 <= y1; passing
    // them swapped collapses the rectangle to a single edge or
    // empty draw via hline/line's own normalisation.

    // Filled rectangle (inclusive endpoints). Implemented as a
    // tight loop of hlines - each row uses the bulk-byte fast
    // path, so an N-row by M-pixel fill scales as N*ceil(M/8) +
    // O(N) loop overhead instead of N*M for a pixel-by-pixel
    // approach. Caller responsible for ordering (x0 <= x1,
    // y0 <= y1); a swapped pair collapses to a single row or
    // empty fill.

    // Outline circle of radius `r` centred at (cx, cy). Bresenham
    // 8-octant: trace one octant (x = 0..y, slope tracked via the
    // decision variable `d`) and reflect each point seven times to
    // cover the rest. With `d = 3 - 2r` and integer increments only
    // - no multiplies inside the loop - each iter advances x by 1
    // and conditionally decrements y, plotting up to 8 pixels via
    // inline:plot so each lands on the per-pixel fast path.
    //
    // Per-pixel cost: ~140 cycles × 8 = ~1120 cycles per iter,
    // ~5000 cycles total for r=8 (3 iters), ~30000 cycles for
    // r=50. The plot bounds-check on each call means partly-off-
    // screen circles work, just slower than fully-on-screen ones.
    //
    // r = 0 plots a single pixel; r < 0 is treated as r = -r.

    // Outline arc — partial circle. `quadrants` is a 4-bit mask:
    //   bit 0 ($01)  NE quadrant (cx+x, cy-y / cx+y, cy-x)
    //   bit 1 ($02)  NW quadrant (cx-x, cy-y / cx-y, cy-x)
    //   bit 2 ($04)  SW quadrant (cx-x, cy+y / cx-y, cy+x)
    //   bit 3 ($08)  SE quadrant (cx+x, cy+y / cx+y, cy+x)
    //
    // 0 = no draw, $0F = full circle (same shape as circle()).
    // Atari y is screen-down, so "north" quadrants are above the
    // centre (cy-y) and "south" are below (cy+y).
    //
    // Same Bresenham 8-octant trace as circle(); each iteration
    // emits only the reflections whose quadrant bit is set. The
    // mask test is one AND + BNE per quadrant per iter, ~10
    // cycles overhead vs circle()'s unconditional 8-plot path.

    // Filled disk of radius r centred at (cx, cy). Walks the same
    // Bresenham step sequence as circle() but emits a horizontal
    // scanline instead of a single pixel at each octant. The two
    // pairs `cx ± y` (a wide row at offset ± x) and `cx ± x` (a
    // narrow row at offset ± y) cover the disk; we draw the wide
    // pair every iter (2 hlines) and the narrow pair only when y
    // decrements, so each y-row gets exactly one hline call.
    //
    // For r ≤ 0 falls back to the outline path (single pixel for
    // r=0, mirror to plot via `if (r < 0) r = -r;`).

    // Filled arc — partial filled disk by quadrant mask. Same
    // bit assignment as arc():  $01 NE, $02 NW, $04 SW, $08 SE.
    //
    // Each Bresenham iter emits at most four hline segments
    // — one per quadrant — clipped to the half-row that
    // belongs to that quadrant. The wide rows (full diameter
    // at offset ± x from centre) split into left half (NW/SW)
    // and right half (NE/SE) at column cx; the narrow rows (at
    // offset ± y from centre, drawn when y just stepped down)
    // split the same way. A wedge bounded by two axes on the
    // boundaries of the requested quadrants — the pure
    // 90°-multiple form. For arbitrary-angle wedges the
    // caller can compose: fillArc + plot the bounding radii.
    //
    // Centre column (the cx column itself) is emitted by the
    // hline whose endpoints include cx; with hline normalising
    // operand order, hline(cx, cx + n, y) covers cx through
    // cx+n inclusive, so the centre is shared between adjacent
    // E/W quadrants on the same row (idempotent under both
    // pen=1 OR and pen=0 AND).

    // Pie outline = arc + radial lines along each axis whose two
    // adjacent quadrants disagree on the mask. A boundary line is
    // only drawn when one of the neighbouring quadrants is "in"
    // and the other is "out" — neighbours both in means the pie
    // crosses that axis without a chord, both out means the pie
    // doesn't reach the axis at all. Quadrant bit layout matches
    // arc(): bit 0 = top-right, bit 1 = top-left, bit 2 = bottom-
    // left, bit 3 = bottom-right.
    //
    //   pie(cx, cy, r, $01)         single TR slice (3 lines + arc)
    //   pie(cx, cy, r, $03)         top half pie    (2 horiz radii)
    //   pie(cx, cy, r, $0F)         full circle     (no radii drawn)
    //   pie(cx, cy, r, $05)         X-shape: TR+BL, 4 radii + 2 arcs

    // Filled pie. The disk-fill that fillArc emits is already
    // bounded by the radial axes between quadrants, so a quadrant-
    // mask "filled pie" is identical to fillArc — keep the name for
    // discoverability and forward-compat with future arc-bounded-
    // by-arbitrary-angles overloads.

    // Outline ellipse with semi-axes (rx, ry) centred at (cx, cy).
    // Standard midpoint algorithm, two-region - region 1 covers
    // the shallow-slope arc near the top/bottom, region 2 covers
    // the steep-slope arc near the left/right. The decision
    // variable P is scaled by 4 so the rx²/4 init term stays
    // integer; with rx,ry up to ~160 the scaled magnitude stays
    // well inside i32 (4·rx²·ry ≈ 10 M for full-screen radii).
    //
    // No i32 multiplies inside the loop - `fourPx` (= 4·ry²·x)
    // and `negFourPy` (= -4·rx²·y, sign-folded so updates are
    // adds) are tracked as running totals updated by `eightRy2`
    // and `eightRx2` constants at each step.
    //
    // rx == ry collapses to a circle but goes through this slower
    // path - call `circle` instead when you know the radii match.
    // r == 0 axes degrade to point / line.

    // Filled ellipse. Same Bresenham step sequence as oval(), but
    // emits horizontal scanlines instead of point-plotting:
    //   - region 1: x grows every iter, y sometimes steps. Emit
    //     the hline pair at the OLD y just before y--, using the
    //     widest x reached at that y.
    //   - boundary row (region 1's last y / region 2's first y):
    //     emitted explicitly between the loops.
    //   - region 2: y always steps. Emit the hline pair at the
    //     NEW y immediately after the step.
    //
    // Each y-row gets exactly one hline pair, so the overdraw is
    // zero. The top/bottom couple of rows may be a pixel or two
    // wider than a strict "inside the curve" fill (Bresenham's
    // staircase), matching the convention used by the Atari OS
    // and most 8-bit graphics libraries.

    // floodFill helper: scan one row in [xL..xR] for runs of
    // `seedColor` pixels, push the leftmost x of each run as a new
    // seed onto the floodFill queue. Drops pushes silently when
    // the queue is full (sets _gfx8_ff_ovf so floodFill returns
    // false).

    // Flood fill from seed (sx, sy). Replaces every pixel in the
    // 4-connected region whose value matches the seed pixel's
    // current colour with `fillColor`. Stops at any pixel whose
    // colour differs from the seed's colour at function entry.
    //
    // Algorithm: scanline fill. Each iteration pops a seed (x, y),
    // walks left + right to find the run of seed-coloured pixels
    // it belongs to, fills that run via hline, then scans the rows
    // immediately above and below for fresh seed-coloured runs and
    // pushes the leftmost x of each as a new seed. Re-pushing the
    // same span is harmless: by the time it is popped, the row has
    // already been filled and the entry-point getPixel check skips
    // it.
    //
    // Frontier policy: the seed queue is a 256-entry ring buffer
    // (heap-allocated lazily on the first call — see _gfx8_ff_xLo
    // / _gfx8_ff_xHi / _gfx8_ff_ys at the top of this file). When
    // a push would exceed 256 pending seeds the push is dropped,
    // the function returns false, and the caller can re-seed any
    // unfilled hole. Pathological inputs (e.g. a complete 320x192
    // fill from a 100-pixel-tall S-shape) can hit this; well-
    // formed regions on a 40-byte-wide screen generally do not.
    //
    // Off-screen seeds (sx, sy out of [0,319] x [0,191]) and
    // already-correct seeds (the pixel already equals fillColor)
    // are no-ops and return true.

    // Quadratic Bezier curve through control point (x1, y1) from
    // (x0, y0) to (x2, y2). Walks t = 0..1 in N=32 fixed steps via
    // forward-difference fixed-point arithmetic, then connects
    // consecutive samples with line() so visible gaps are
    // impossible even on bowed curves with off-screen control
    // points.
    //
    // B(t) = (1-t)^2 P0 + 2(1-t)t P1 + t^2 P2
    //      = a*t^2 + b*t + c
    //   where  a = P0 - 2*P1 + P2
    //          b = 2*(P1 - P0)
    //          c = P0
    //
    // Forward differences scaled by N^2 = 1024 so all state stays
    // in i32 with no per-step multiplies:
    //   F(0)  = c * 1024     (= c << 10)
    //   dF(0) = a + b*N      (= a + (b << 5))
    //   d2F   = 2*a          (= a << 1; constant second difference)
    // Per step:  F += dF;  dF += d2F;  sample at F >> 10.
    //
    // Initial conditions are exact integers and FD only adds, so
    // F at the final iter exactly equals P2*1024 — no endpoint
    // drift. `here` is left at (x2, y2).

    // Cursor-based Bezier: P0 = `here`, control point (x1, y1),
    // endpoint (x2, y2). Same shape as lineTo's relationship to
    // line — chains naturally for path drawing where each segment
    // continues from the previous endpoint.

    // Point-taking bezierTo: control + endpoint as Points. P0 is
    // `at` as before, the curve advances `at` to p2.
    }
