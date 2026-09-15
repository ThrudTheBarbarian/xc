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

// Gfx7.xc - GR.7 (160x96 4-colour) primitives for the Gfx master class.
//
// Memory layout:
//   - Screen RAM is 160*96/4 = 3840 bytes at sbase.
//   - Each row is 40 bytes (160 px / 4 pixels per byte = 40 bytes).
//   - Each byte stores 4 pixels, 2 bits each.
//   - Pixel at (x, y) lives in byte sbase + y*40 + (x>>2).
//   - Bit position for pixel p (0-3) in a byte: shift = 6 - (p << 1)
//   - To extract: (byte >> shift) & 3
//   - To set: clear bits then OR new value shifted to position
//
// Colours are specified via COLOR0-COLOR3 registers ($D016-$D019).
// The 2-bit value in screen RAM selects which colour register to use.

#import "Stdio.xc"
#import "Gfx.xc"

// Y-row offset tables: _gfx7_yLo[y] and _gfx7_yHi[y] give y*40
u8 _gfx7_yLo[96];
u8 _gfx7_yHi[96];

// Display list for GR.7 (ANTIC mode D = $0D, 4 colours, 160x96).
// 24 BLANK scanlines (top margin) + 96 mode-D rows + JVB back to
// start. Total 105 bytes. All 3840 screen bytes fit inside one
// ANTIC 4 KB fetch boundary at $8000-$8EFF, so a single LMS at
// the top is enough — no second LMS required.
u8 _gfx7_dlist[105] = {
    $70, $70, $70,                                    // 3 BLANK (24 scanlines)
    $4D, $00, $80,                                    // LMS mode D at $8000
    $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, // 10
    $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, // 20
    $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, // 30
    $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, // 40
    $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, // 50
    $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, // 60
    $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, // 70
    $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, // 80
    $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, // 90
    $0D, $0D, $0D, $0D, $0D, $0D,                     // 96
    $41, $00, $80                                     // JVB target $8000
};

// Pixel mask table: mask[i] gives the 2-bit mask for pixel position i
// shift = 6 - i*2, mask = 3 << shift = $C0, $30, $0C, $03
u8 _gfx7_mask[4] = {$C0, $30, $0C, $03};

// OR table for plot: orTable[col*4 + px] gives the OR mask that
// deposits 2-bit colour `col` into pixel position `px` of a byte.
// px in 0..3 maps to bit positions 7..6, 5..4, 3..2, 1..0
// (high-bit first), so the mask is col << (6 - px*2).
u8 _gfx7_orTable[16] = {
    $00, $00, $00, $00, // col=0 (no bits set)
    $40, $10, $04, $01, // col=1
    $80, $20, $08, $02, // col=2
    $C0, $30, $0C, $03  // col=3
};

// hline bulk-byte fast-path tables. Each entry is a byte mask
// covering a contiguous range of 2-bit pixel fields. `partLeft`
// covers pixels b..3 of a byte (used on the leftmost byte where
// b is the bit-pair index of the line's left endpoint within
// that byte). `partRight` covers pixels 0..b (used on the
// rightmost byte). `clrLeft` / `clrRight` are the bitwise
// complements; pre-computing them saves an EOR per inner-loop
// iteration.
u8 _gfx7_partLeft[4] = {$FF, $3F, $0F, $03};
u8 _gfx7_partRight[4] = {$C0, $F0, $FC, $FF};
u8 _gfx7_clrLeft[4] = {$00, $C0, $F0, $FC};
u8 _gfx7_clrRight[4] = {$3F, $0F, $03, $00};

// 4x replication of a 2-bit colour into a full byte: colourFill[c]
// = (c << 6) | (c << 4) | (c << 2) | c. Covers pen ∈ {0..3}.
u8 _gfx7_colourFill[4] = {$00, $55, $AA, $FF};

// prepare: 1 if buildTables() has been called
u8 _gfx7_ready = 0;

// Build the Y-row offset lookup tables (y*40 for y in 0..95)
void _gfx7_buildTables(void)
    {
    if (_gfx7_ready != 0)
        {
        return;
        }
    u16 acc = 0;
    u8 i = 0;
    while (i < 96)
        {
        _gfx7_yLo[i] = (u8)(acc & $FF);
        _gfx7_yHi[i] = (u8)(acc >> 8);
        acc = acc + 40;
        i = i + 1;
        }
    _gfx7_ready = 1;
    return;
    }

class Gfx7 : Gfx
    {
    // Zero-arg init: reads screen base from SAVMSC after GRAPHICS 7
    void init(void)
        {
        readFromOS();
        at.x = 0;
        at.y = 0;
        pen = 1;
        fillColor = 0;
        clearBytes = 3840;
        _width = 160;
        _height = 96;
        if (_gfx7_ready == 0)
            {
            _gfx7_buildTables();
            }
        return;
        }

    // Construct against an explicit heap-buffer screen base
    void init(u8* buf)
        {
        sbase = (u16)buf;
        u8 bk;
        asm { LDA buf+2 : STA bk }
        sbank = bk; // capture the buffer's data bank (private:docs/bugs/007)
        at.x = 0;
        at.y = 0;
        pen = 1;
        fillColor = 0;
        clearBytes = 3840;
        _width = 160;
        _height = 96;
        if (_gfx7_ready == 0)
            {
            _gfx7_buildTables();
            }
        return;
        }

    // Update the screen base post-construction
    void setBase(u16 base)
        {
        sbase = base;
        return;
        }

    // Read screen base from SAVMSC ($58/$59)
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

    // Set up GR.7 without going through OS GRAPHICS 7 command
    void setupNative(void)
        {
        sbase = $8000;
        clearBytes = 3840;
        _width = 160;
        _height = 96;
        if (_gfx7_ready == 0)
            {
            _gfx7_buildTables();
            }
        asm
        {
            SEI
            ; Copy DL to $8000. The 105-byte dlist already has the
            ; LMS target ($8000) and JVB target ($8000) baked into
            ; its initialiser, so a straight copy is enough -- no
            ; runtime patch needed.
            LDA #<_gfx7_dlist
            STA $B0
            LDA #>_gfx7_dlist
            STA $B1
            LDA #$00
            STA $B2
            LDA #$80
            STA $B3
            LDX #105
            LDY #$00
        _gfx7_dl_copy:
            LDA ($B0),Y
            STA ($B2),Y
            INY
            DEX
            BNE _gfx7_dl_copy

            ; Disable display
            LDA #$00
            STA $D400
            ; Point ANTIC at the $8000 DL
            LDA #$00
            STA $0230
            STA $D402
            LDA #$80
            STA $0231
            STA $D403
            ; SAVMSC = $8000
            LDA #$00
            STA $58
            LDA #$80
            STA $59
            ; CHACTL default
            LDA #$02
            STA $D401
            ; Re-enable display
            LDA #$22
            STA $D400
            CLI
        }
        return;
        }

    // Plot a pixel at (x, y) with colour (0-3)
    // Branchless implementation using precomputed OR table
    void plot(i16 x, i16 y)
        {
        if (x < 0 || x >= 160)
            {
            return;
            }
        if (y < 0 || y >= 96)
            {
            return;
            }

        u8 px = (u8)x;       // x coordinate (0-159)
        u8 py = (u8)y;       // y coordinate (0-95)
        u8 col = pen;        // colour (0-3)
        u16 _g7p_sb = sbase; // stage ivar — bare `sbase` in asm
                             // resolves to a non-existent
                             // __sdata_Gfx7 label for heap-class
                             // instances.

        u16 _gfx_zp_ptr;
        u8 _g7p_byte;
        u8 _g7p_idx;    // table index = col*4 + px
        u8 _g7p_xdiv4;  // px >> 2
        u8 _g7p_addrLo; // intermediate address low byte
        u8 _g7p_addrHi; // intermediate address high byte

        u8 _g7p_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g7p_sbk
            STA __bank_data_reg
            ; Calculate y*40 low and high bytes
            LDY py
            LDA _gfx7_yLo,Y
            STA _g7p_addrLo
            LDA _gfx7_yHi,Y
            STA _g7p_addrHi

            ; px >> 2 = px / 4
            LDA px
            LSR A
            LSR A
            STA _g7p_xdiv4

            ; Add low bytes: sbase_lo + y_lo + (px>>2)
            CLC
            LDA _g7p_sb
            ADC _g7p_addrLo
            ADC _g7p_xdiv4
            STA _gfx_zp_ptr

            ; Add high bytes with carry: sbase_hi + y_hi + carry
            LDA _g7p_sb+1
            ADC _g7p_addrHi
            STA _gfx_zp_ptr+1

            ; Clear the 2-bit field at pixel position (px & 3).
            ; _gfx7_mask[(px&3)] is $C0/$30/$0C/$03, the bits to
            ; CLEAR; EOR #$FF inverts it for the AND-clear.
            LDA px
            AND #$03
            STA _g7p_idx            ; stash (px & 3) for index calc
            TAX
            LDA _gfx7_mask,X
            EOR #$FF
            LDY #$00
            AND (_gfx_zp_ptr),Y
            STA _g7p_byte

            ; Compute table index: col*4 + (px & 3). Using the
            ; raw px here would index off the end of the 16-byte
            ; orTable for any x coordinate >= 4 and pull garbage
            ; (or the next-pixel column) into the byte.
            LDA col
            ASL A
            ASL A                   ; col*4
            CLC
            ADC _g7p_idx            ; + (px & 3)
            STA _g7p_idx

            ; Load OR value from table and apply
            LDA _g7p_idx
            TAX
            LDA _gfx7_orTable,X
            ORA _g7p_byte
            STA (_gfx_zp_ptr),Y
        }
        return;
        }

    // Read a pixel's colour (0-3)
    // Branchless implementation using precomputed shift masks
    u8 getPixel(i16 x, i16 y)
        {
        if (x < 0 || x >= 160)
            {
            return 0;
            }
        if (y < 0 || y >= 96)
            {
            return 0;
            }

        u8 px = (u8)x;
        u8 py = (u8)y;
        u8 result;
        u16 _g7g_sb = sbase;

        // Precomputed shift amounts for each pixel position
        // pixel 0 -> shift 6, pixel 1 -> shift 4, pixel 2 -> shift 2, pixel 3 -> shift 0
        u8 _g7g_shifts[4] = {$06, $04, $02, $00};

        u16 _gfx_zp_ptr;
        u8 _g7g_byte;
        u8 _g7g_px;

        u8 _g7g_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g7g_sbk
            STA __bank_data_reg
            ; ptr = sbase + yTable[py]
            LDY py
            CLC
            LDA _g7g_sb
            ADC _gfx7_yLo,Y
            STA _gfx_zp_ptr
            LDA _g7g_sb+1
            ADC _gfx7_yHi,Y
            STA _gfx_zp_ptr+1

            ; ptr += (px >> 2). LSR feeds carry, so CLC before ADC.
            LDA px
            LSR A
            LSR A
            CLC
            ADC _gfx_zp_ptr
            STA _gfx_zp_ptr
            BCC _g7g_no_carry
            INC _gfx_zp_ptr+1
        _g7g_no_carry:

            ; Compute shift count: shifts[(px & 3)]. shift in
            ; 0, 2, 4, 6.
            LDA px
            AND #$03
            TAX
            LDA _g7g_shifts,X
            STA _g7g_px

            ; Load byte, then LSR A shift times, mask low 2 bits.
            LDY #$00
            LDA (_gfx_zp_ptr),Y
            LDX _g7g_px
            BEQ _g7g_extract
        _g7g_lsr_lp:
            LSR A
            DEX
            BNE _g7g_lsr_lp
        _g7g_extract:
            AND #$03
            STA result
        }
        return result;
        }

    // Horizontal line from x0 to x1 at row y. Bulk-byte fast
    // path: at 2bpp each byte holds 4 colour fields, so a single
    // STA fills 4 pixels at once. Edge bytes (where the line's
    // endpoint falls mid-byte) take a read-modify-write that
    // ANDs out the touched fields and ORs in the per-byte fill
    // colour through partLeft / partRight masks. Single-byte
    // case (byteL == byteR) is one RMW.
    //
    // Cost: ~25 cycles per middle byte (4 pixels) + ~50 cycles
    // for each edge byte. A 160-wide line runs in ~1ms vs ~22ms
    // for the per-pixel inline:plot fallback.
    void hline(i16 x0, i16 x1, i16 y)
        {
        if (y < 0 || y >= 96)
            {
            return;
            }

        i16 lo = x0;
        i16 hi = x1;
        if (lo > hi)
            {
            lo = x1;
            hi = x0;
            }
        if (hi < 0 || lo >= 160)
            {
            return;
            }
        if (lo < 0)
            {
            lo = 0;
            }
        if (hi >= 160)
            {
            hi = 159;
            }

        u8 _g7h_y = (u8)y;
        u8 _g7h_lo = (u8)lo;
        u8 _g7h_hi = (u8)hi;
        u8 _g7h_pen = pen;
        u16 _g7h_sb = sbase;

        u16 _gfx_zp_ptr;
        u8 _g7h_bL;   // byte index of leftmost touched byte
        u8 _g7h_bR;   // byte index of rightmost touched byte
        u8 _g7h_iL;   // pixel index within bL (0..3)
        u8 _g7h_iR;   // pixel index within bR (0..3)
        u8 _g7h_fill; // colour byte (pen replicated × 4)
        u8 _g7h_mask; // scratch byte mask
        u8 _g7h_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g7h_sbk
            STA __bank_data_reg
            ; ptr = sbase + yTable[y].
            LDY _g7h_y
            CLC
            LDA _g7h_sb
            ADC _gfx7_yLo,Y
            STA _gfx_zp_ptr
            LDA _g7h_sb+1
            ADC _gfx7_yHi,Y
            STA _gfx_zp_ptr+1

            ; byteL = lo >> 2, iL = lo & 3.
            LDA _g7h_lo
            LSR A
            LSR A
            STA _g7h_bL
            LDA _g7h_lo
            AND #$03
            STA _g7h_iL

            ; byteR = hi >> 2, iR = hi & 3.
            LDA _g7h_hi
            LSR A
            LSR A
            STA _g7h_bR
            LDA _g7h_hi
            AND #$03
            STA _g7h_iR

            ; fill = colourFill[pen & 3].
            LDX _g7h_pen
            LDA _gfx7_colourFill,X
            STA _g7h_fill

            ; Single-byte case: byteL == byteR.
            ; mask = partLeft[iL] AND partRight[iR];
            ; byte = (byte AND NOT mask) OR (fill AND mask)
            ;      = (byte AND clearBits) OR (fill AND mask)
            ; where clearBits = clrLeft[iL] OR clrRight[iR].
            LDA _g7h_bL
            CMP _g7h_bR
            BNE _g7h_multi
            LDX _g7h_iL
            LDA _gfx7_partLeft,X
            LDX _g7h_iR
            AND _gfx7_partRight,X     ; A = touched-bits mask
            STA _g7h_mask
            LDA _g7h_fill
            AND _g7h_mask             ; A = colour bits to OR
            STA _g7h_fill             ; reuse as scratch
            LDA _g7h_mask
            EOR #$FF                  ; A = clear-bits mask
            LDY _g7h_bL
            AND (_gfx_zp_ptr),Y
            ORA _g7h_fill
            STA (_gfx_zp_ptr),Y
            JMP _g7h_done
        _g7h_multi:
            ; Left partial: byte at bL.
            ; new = (old AND clrLeft[iL]) OR (fill AND partLeft[iL])
            LDX _g7h_iL
            LDA _g7h_fill
            AND _gfx7_partLeft,X
            STA _g7h_mask
            LDA _gfx7_clrLeft,X
            LDY _g7h_bL
            AND (_gfx_zp_ptr),Y
            ORA _g7h_mask
            STA (_gfx_zp_ptr),Y

            ; Middle bytes: bL+1 .. bR-1, each byte = fill.
            ; Count = bR - bL - 1; BEQ skips when adjacent.
            INY
            LDA _g7h_bR
            SEC
            SBC _g7h_bL
            SEC
            SBC #$01
            TAX
            BEQ _g7h_right
            LDA _g7h_fill
        _g7h_mid:
            STA (_gfx_zp_ptr),Y
            INY
            DEX
            BNE _g7h_mid
        _g7h_right:
            ; Right partial: byte at bR.
            LDX _g7h_iR
            LDA _g7h_fill
            AND _gfx7_partRight,X
            STA _g7h_mask
            LDA _gfx7_clrRight,X
            LDY _g7h_bR
            AND (_gfx_zp_ptr),Y
            ORA _g7h_mask
            STA (_gfx_zp_ptr),Y
        _g7h_done:
        }
        return;
        }

    // Vertical line at column x from y0 to y1
    void vline(i16 x, i16 y0, i16 y1)
        {
        if (x < 0 || x >= 160)
            {
            return;
            }
        if (y0 < 0)
            y0 = 0;
        if (y1 < 0)
            y1 = 0;
        if (y0 >= 96)
            y0 = 95;
        if (y1 >= 96)
            y1 = 95;
        if (y0 > y1)
            {
            i16 t = y0;
            y0 = y1;
            y1 = t;
            }

        u8 px = (u8)x;
        u8 py0 = (u8)y0;
        u8 col = pen;
        u16 _g7v_sb = sbase;

        u16 _gfx_zp_ptr;
        u8 _g7v_byte;
        u8 _g7v_shift;
        u8 _g7v_orMask;
        u8 _g7v_clrMask; // inverted 2-bit field mask — AND
                         // it into the byte to clear the
                         // pixel's slot before OR-ing the
                         // new colour. Without this the
                         // pen=0 path was a pure OR-with-0
                         // no-op, leaving any previously-
                         // lit colour at this column intact.
        u16 _g7v_count = (u16)(y1 - y0 + 1);
        u8 _g7v_cntLo = (u8)(_g7v_count & $FF);
        u8 _g7v_cntHi = (u8)(_g7v_count >> 8);

        u8 _g7v_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g7v_sbk
            STA __bank_data_reg
            ; byte = x >> 2, shift = 6 - ((x & 3) * 2). Result is
            ; one of 0, 2, 4, 6; an extra ASL here would push it
            ; into 0/4/8/12 and the OR mask would shift the
            ; colour off the byte entirely.
            LDA px
            LSR A
            LSR A
            STA _g7v_byte
            LDA px
            AND #$03
            ASL A
            EOR #$06
            STA _g7v_shift

            ; Calculate start address
            LDY py0
            CLC
            LDA _g7v_sb
            ADC _gfx7_yLo,Y
            STA _gfx_zp_ptr
            LDA _g7v_sb+1
            ADC _gfx7_yHi,Y
            STA _gfx_zp_ptr+1
            LDA _g7v_byte
            CLC
            ADC _gfx_zp_ptr
            STA _gfx_zp_ptr
            BCC _g7v_no_carry
            INC _gfx_zp_ptr+1
        _g7v_no_carry:

            ; colour value to OR: col << shift. shift is one of
            ; 0, 2, 4 or 6; for shift == 0 skip the loop entirely.
            LDA col
            LDX _g7v_shift
            BEQ _g7v_shift_done
        _g7v_shift_col:
            ASL A
            DEX
            BNE _g7v_shift_col
        _g7v_shift_done:
            STA _g7v_orMask

            ; Field-clear mask: $03 << shift, then complemented.
            ; $03 covers the 2-bit colour slot; shifting puts it
            ; at the right position in the byte; EOR #$FF turns
            ; it into "AND-this-to-clear-the-slot". Pre-fix the
            ; loop body was a pure OR, so pen=0 (col=0; orMask=0)
            ; couldn't erase a previously-lit pixel.
            LDA #$03
            LDX _g7v_shift
            BEQ _g7v_clr_done
        _g7v_clr_shift:
            ASL A
            DEX
            BNE _g7v_clr_shift
        _g7v_clr_done:
            EOR #$FF
            STA _g7v_clrMask

            ; Loop through (y1 - y0 + 1) rows. 16-bit countdown
            ; on _g7v_cntLo / _g7v_cntHi (same shape as Gfx8).
            LDY #$00
        _g7v_loop:
            LDA (_gfx_zp_ptr),Y
            AND _g7v_clrMask
            ORA _g7v_orMask
            STA (_gfx_zp_ptr),Y
            ; Advance to next row (byte address + 40)
            CLC
            LDA _gfx_zp_ptr
            ADC #$28
            STA _gfx_zp_ptr
            BCC _g7v_no_carry2
            INC _gfx_zp_ptr+1
        _g7v_no_carry2:
            ; 16-bit countdown.
            LDA _g7v_cntLo
            BNE _g7v_dec
            LDA _g7v_cntHi
            BEQ _g7v_done
            DEC _g7v_cntHi
        _g7v_dec:
            DEC _g7v_cntLo
            LDA _g7v_cntLo
            ORA _g7v_cntHi
            BNE _g7v_loop
        _g7v_done:
        }
        return;
        }
    }
