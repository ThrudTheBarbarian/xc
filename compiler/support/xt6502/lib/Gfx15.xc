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

// Gfx15.xc - GR.15 (160x192 4-colour) primitives for the Gfx
// master class.
//
// Memory layout:
//   - Screen RAM is 160*192/4 = 7680 bytes at sbase.
//   - Each row is 40 bytes (160 px / 4 pixels per byte).
//   - Each byte stores 4 pixels, 2 bits each.
//   - Pixel at (x, y) lives in byte sbase + y*40 + (x>>2).
//   - Bit position for pixel p (0-3) in a byte: shift = 6 - (p << 1)
//
// Colours selected via COLOR0-COLOR3 ($D016-$D019). The 2-bit
// value in screen RAM picks which colour register to use.
//
// Compared to GR.7 (Gfx7): same pixel-byte layout but twice the
// vertical resolution — each pixel takes one scanline (ANTIC mode
// E) instead of two (mode D). 7680 bytes of screen RAM rather
// than 3840, which forces a mid-DL LMS at the 4 KB ANTIC fetch
// boundary just like Gfx8.
//
// Compared to GR.8 (Gfx8): same screen-RAM size and DL shape but
// 2bpp colour fields instead of 1bpp. Hline / plot routines are
// near-identical to Gfx7's; only the y-table size and the mode
// byte differ.

#import "Stdio.xc"
#import "Gfx.xc"

// Y-row offset tables: y*40 for y in 0..191.
u8 _gfx15_yLo[192];
u8 _gfx15_yHi[192];

// GR.15 display list (ANTIC mode E = $0E, 4 colours, 160x192).
// 24 BLANK scanlines + 96 mode-E lines starting at $8100 + LMS at
// $9000 + 96 more mode-E lines + JVB back to start. Same shape
// as Gfx8's DL — the 4 KB fetch boundary at $9000 makes the
// mid-DL LMS mandatory; pushing the first LMS to $8100 keeps the
// screen contiguous from $8100 through $9EFF (no gap, byte
// addressing stays plain `sbase + y*40`).
//
// Layout (203 bytes):
//   3x $70    24 blank scanlines
//   $4E + word  LMS mode-E + screen $8100
//   95x $0E   95 more mode-E (96 total in this LMS section)
//   $4E + word  LMS mode-E + second-half $9000
//   95x $0E   95 more mode-E (192 total = full screen height)
//   $41 + word  JVB target patched at setupNative() time
u8 _gfx15_dlist[203] = {
    $70, $70, $70,
    $4E, $00, $81,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E,
    $4E, $00, $90,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E,
    $0E, $0E, $0E, $0E, $0E,
    $41, $00, $00};

// Pixel mask table: mask[i] gives the 2-bit mask for pixel i.
u8 _gfx15_mask[4] = {$C0, $30, $0C, $03};

// OR table for plot: orTable[col*4 + px] deposits 2-bit colour
// `col` into pixel position `px` of a byte.
u8 _gfx15_orTable[16] = {
    $00, $00, $00, $00, // col=0
    $40, $10, $04, $01, // col=1
    $80, $20, $08, $02, // col=2
    $C0, $30, $0C, $03  // col=3
};

// hline bulk-byte fast-path tables. partLeft[b] covers pixels b..3
// of a byte; partRight[b] covers 0..b. clrLeft / clrRight are the
// bitwise complements pre-computed to save an EOR per inner-loop
// iteration. 4x replication of a 2-bit colour into a full byte
// is colourFill[c] = (c<<6)|(c<<4)|(c<<2)|c.
u8 _gfx15_partLeft[4] = {$FF, $3F, $0F, $03};
u8 _gfx15_partRight[4] = {$C0, $F0, $FC, $FF};
u8 _gfx15_clrLeft[4] = {$00, $C0, $F0, $FC};
u8 _gfx15_clrRight[4] = {$3F, $0F, $03, $00};
u8 _gfx15_colourFill[4] = {$00, $55, $AA, $FF};

u8 _gfx15_ready = 0;

// Build the y*40 lookup tables for y in 0..191.
void _gfx15_buildTables(void)
    {
    if (_gfx15_ready != 0)
        {
        return;
        }
    u16 acc = 0;
    u16 i = 0;
    while (i < (u16)192)
        {
        _gfx15_yLo[i] = (u8)(acc & $FF);
        _gfx15_yHi[i] = (u8)(acc >> 8);
        acc = acc + (u16)40;
        i = i + (u16)1;
        }
    _gfx15_ready = 1;
    return;
    }

class Gfx15 : Gfx
    {
    // Zero-arg init: reads screen base from SAVMSC after a
    // GRAPHICS 15 command has been issued via Gfx.setMode(15).
    void init(void)
        {
        readFromOS();
        at.x = 0;
        at.y = 0;
        pen = 1;
        fillColor = 0;
        clearBytes = 7680;
        _width = 160;
        _height = 192;
        if (_gfx15_ready == 0)
            {
            _gfx15_buildTables();
            }
        return;
        }

    // Construct against an explicit heap-buffer screen base.
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
        clearBytes = 7680;
        _width = 160;
        _height = 192;
        if (_gfx15_ready == 0)
            {
            _gfx15_buildTables();
            }
        return;
        }

    void setBase(u16 base)
        {
        sbase = base;
        return;
        }

    // Read screen base from SAVMSC ($58/$59).
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

    // Set up GR.15 without going through OS GRAPHICS 15. Copies
    // the prebuilt display list to $8000 (with the JVB target
    // patched in), points ANTIC at it, and re-arms the screen
    // base (SAVMSC) to $8100 so subsequent OS lookups agree with
    // the LMS chosen above.
    void setupNative(void)
        {
        sbase = $8100;
        clearBytes = 7680;
        _width = 160;
        _height = 192;
        if (_gfx15_ready == 0)
            {
            _gfx15_buildTables();
            }
        // Patch JVB target in the prebuilt DL to point at $8000
        // (we copy the DL there). The literal initializer can't
        // reference its own address, so do it at run time.
        _gfx15_dlist[200] = $00;
        _gfx15_dlist[201] = $80;
        asm
        {
            SEI
            ; Copy DL to $8000.
            LDA #<_gfx15_dlist
            STA $B0
            LDA #>_gfx15_dlist
            STA $B1
            LDA #$00
            STA $B2
            LDA #$80
            STA $B3
            LDX #203
            LDY #$00
        _gfx15_dl_copy:
            LDA ($B0),Y
            STA ($B2),Y
            INY
            DEX
            BNE _gfx15_dl_copy
            ; Disable display
            LDA #$00
            STA $D400
            ; Point ANTIC at $8000
            LDA #$00
            STA $0230
            STA $D402
            LDA #$80
            STA $0231
            STA $D403
            ; SAVMSC = $8100
            LDA #$00
            STA $58
            LDA #$81
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

    // Plot a pixel at (x, y) with colour from `pen` (0-3).
    void plot(i16 x, i16 y)
        {
        if (x < 0 || x >= 160)
            {
            return;
            }
        if (y < 0 || y >= 192)
            {
            return;
            }

        u8 px = (u8)x;
        u8 py;
        u8 pyHi;
        u8 col = pen;
        u16 _g15p_sb = sbase;

        u16 _gfx_zp_ptr;
        u8 _g15p_byte;
        u8 _g15p_idx;
        u8 _g15p_xdiv4;
        u8 _g15p_addrLo;
        u8 _g15p_addrHi;

        py = (u8)((u16)y & $FF);
        pyHi = (u8)((u16)y >> 8);

        u8 _g15p_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g15p_sbk
            STA __bank_data_reg
            ; Calculate y*40 by indexing into the 192-entry lookup
            ; tables. Y = (low 8 bits of y) when y < 256; y >= 192
            ; was bounds-checked so high byte is always 0.
            LDY py
            LDA _gfx15_yLo,Y
            STA _g15p_addrLo
            LDA _gfx15_yHi,Y
            STA _g15p_addrHi

            ; px >> 2 = byte offset within row
            LDA px
            LSR A
            LSR A
            STA _g15p_xdiv4

            ; ptr = sbase + y*40 + (px>>2)
            CLC
            LDA _g15p_sb
            ADC _g15p_addrLo
            ADC _g15p_xdiv4
            STA _gfx_zp_ptr
            LDA _g15p_sb+1
            ADC _g15p_addrHi
            STA _gfx_zp_ptr+1

            ; Clear the 2-bit pixel field. mask[(px&3)] gives the
            ; bits to clear; EOR #$FF inverts for AND.
            LDA px
            AND #$03
            STA _g15p_idx
            TAX
            LDA _gfx15_mask,X
            EOR #$FF
            LDY #$00
            AND (_gfx_zp_ptr),Y
            STA _g15p_byte

            ; index = col*4 + (px&3)
            LDA col
            ASL A
            ASL A
            CLC
            ADC _g15p_idx
            STA _g15p_idx

            ; OR in the colour bits
            LDX _g15p_idx
            LDA _gfx15_orTable,X
            ORA _g15p_byte
            STA (_gfx_zp_ptr),Y
        }
        return;
        }

    // Read a pixel's colour (0..3).
    u8 getPixel(i16 x, i16 y)
        {
        if (x < 0 || x >= 160)
            {
            return 0;
            }
        if (y < 0 || y >= 192)
            {
            return 0;
            }

        u8 px = (u8)x;
        u8 py = (u8)((u16)y & $FF);
        u8 result;
        u16 _g15g_sb = sbase;
        u8 _g15g_shifts[4] = {$06, $04, $02, $00};

        u16 _gfx_zp_ptr;
        u8 _g15g_shift;

        u8 _g15g_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g15g_sbk
            STA __bank_data_reg
            LDY py
            CLC
            LDA _g15g_sb
            ADC _gfx15_yLo,Y
            STA _gfx_zp_ptr
            LDA _g15g_sb+1
            ADC _gfx15_yHi,Y
            STA _gfx_zp_ptr+1
            LDA px
            LSR A
            LSR A
            CLC
            ADC _gfx_zp_ptr
            STA _gfx_zp_ptr
            BCC _g15g_no_carry
            INC _gfx_zp_ptr+1
        _g15g_no_carry:
            LDA px
            AND #$03
            TAX
            LDA _g15g_shifts,X
            STA _g15g_shift
            LDY #$00
            LDA (_gfx_zp_ptr),Y
            LDX _g15g_shift
            BEQ _g15g_extract
        _g15g_lsr_lp:
            LSR A
            DEX
            BNE _g15g_lsr_lp
        _g15g_extract:
            AND #$03
            STA result
        }
        return result;
        }

    // Horizontal line from x0 to x1 at row y. Bulk-byte fast path
    // identical in shape to Gfx7's: per-byte fill colour fills
    // each middle byte with one STA, edge bytes get an AND-clear
    // / OR-fill via the partLeft/partRight masks.
    void hline(i16 x0, i16 x1, i16 y)
        {
        if (y < 0 || y >= 192)
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

        u8 _g15h_y = (u8)((u16)y & $FF);
        u8 _g15h_lo = (u8)lo;
        u8 _g15h_hi = (u8)hi;
        u8 _g15h_pen = pen;
        u16 _g15h_sb = sbase;

        u16 _gfx_zp_ptr;
        u8 _g15h_bL;
        u8 _g15h_bR;
        u8 _g15h_iL;
        u8 _g15h_iR;
        u8 _g15h_fill;
        u8 _g15h_mask;
        u8 _g15h_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g15h_sbk
            STA __bank_data_reg
            LDY _g15h_y
            CLC
            LDA _g15h_sb
            ADC _gfx15_yLo,Y
            STA _gfx_zp_ptr
            LDA _g15h_sb+1
            ADC _gfx15_yHi,Y
            STA _gfx_zp_ptr+1
            LDA _g15h_lo
            LSR A
            LSR A
            STA _g15h_bL
            LDA _g15h_lo
            AND #$03
            STA _g15h_iL
            LDA _g15h_hi
            LSR A
            LSR A
            STA _g15h_bR
            LDA _g15h_hi
            AND #$03
            STA _g15h_iR
            LDX _g15h_pen
            LDA _gfx15_colourFill,X
            STA _g15h_fill
            LDA _g15h_bL
            CMP _g15h_bR
            BNE _g15h_multi
            LDX _g15h_iL
            LDA _gfx15_partLeft,X
            LDX _g15h_iR
            AND _gfx15_partRight,X
            STA _g15h_mask
            LDA _g15h_fill
            AND _g15h_mask
            STA _g15h_fill
            LDA _g15h_mask
            EOR #$FF
            LDY _g15h_bL
            AND (_gfx_zp_ptr),Y
            ORA _g15h_fill
            STA (_gfx_zp_ptr),Y
            JMP _g15h_done
        _g15h_multi:
            LDX _g15h_iL
            LDA _g15h_fill
            AND _gfx15_partLeft,X
            STA _g15h_mask
            LDA _gfx15_clrLeft,X
            LDY _g15h_bL
            AND (_gfx_zp_ptr),Y
            ORA _g15h_mask
            STA (_gfx_zp_ptr),Y
            INY
            LDA _g15h_bR
            SEC
            SBC _g15h_bL
            SEC
            SBC #$01
            TAX
            BEQ _g15h_right
            LDA _g15h_fill
        _g15h_mid:
            STA (_gfx_zp_ptr),Y
            INY
            DEX
            BNE _g15h_mid
        _g15h_right:
            LDX _g15h_iR
            LDA _g15h_fill
            AND _gfx15_partRight,X
            STA _g15h_mask
            LDA _gfx15_clrRight,X
            LDY _g15h_bR
            AND (_gfx_zp_ptr),Y
            ORA _g15h_mask
            STA (_gfx_zp_ptr),Y
        _g15h_done:
        }
        return;
        }

    // Vertical line — bulk-byte path mirroring Gfx7.vline. Each
    // row's byte gets one AND-with-clear-mask + ORA-with-colour
    // + STA, plus an ADC #40 to advance to the next row. ~30
    // cycles per row vs ~150 for the per-pixel inline:plot
    // fallback that the first deliverable shipped. The clear
    // mask before the OR makes pen=0 actually erase (Gfx7's
    // first cut was OR-only and silently no-op'd at pen=0).
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
        if (y0 >= 192)
            y0 = 191;
        if (y1 >= 192)
            y1 = 191;
        if (y0 > y1)
            {
            i16 t = y0;
            y0 = y1;
            y1 = t;
            }

        u8 px = (u8)x;
        u8 py0 = (u8)((u16)y0 & $FF);
        u8 col = pen;
        u16 _g15v_sb = sbase;

        u16 _gfx_zp_ptr;
        u8 _g15v_byte;
        u8 _g15v_shift;
        u8 _g15v_orMask;
        u8 _g15v_clrMask;
        u16 _g15v_count = (u16)(y1 - y0 + 1);
        u8 _g15v_cntLo = (u8)(_g15v_count & $FF);
        u8 _g15v_cntHi = (u8)(_g15v_count >> 8);

        u8 _g15v_sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g15v_sbk
            STA __bank_data_reg
            ; byte = x >> 2, shift = 6 - ((x & 3) * 2). One of
            ; 0, 2, 4, 6.
            LDA px
            LSR A
            LSR A
            STA _g15v_byte
            LDA px
            AND #$03
            ASL A
            EOR #$06
            STA _g15v_shift

            ; Calculate start address: ptr = sbase + yTable[y0]
            ; + byte. y0 < 192 so the high-byte wrap is handled
            ; entirely by yTable.
            LDY py0
            CLC
            LDA _g15v_sb
            ADC _gfx15_yLo,Y
            STA _gfx_zp_ptr
            LDA _g15v_sb+1
            ADC _gfx15_yHi,Y
            STA _gfx_zp_ptr+1
            LDA _g15v_byte
            CLC
            ADC _gfx_zp_ptr
            STA _gfx_zp_ptr
            BCC _g15v_no_carry
            INC _gfx_zp_ptr+1
        _g15v_no_carry:

            ; orMask = col << shift
            LDA col
            LDX _g15v_shift
            BEQ _g15v_or_done
        _g15v_or_shift:
            ASL A
            DEX
            BNE _g15v_or_shift
        _g15v_or_done:
            STA _g15v_orMask

            ; clrMask = NOT ($03 << shift) - the AND mask that
            ; clears the 2-bit field. Without it pen=0 would be
            ; an OR-with-0 no-op.
            LDA #$03
            LDX _g15v_shift
            BEQ _g15v_clr_done
        _g15v_clr_shift:
            ASL A
            DEX
            BNE _g15v_clr_shift
        _g15v_clr_done:
            EOR #$FF
            STA _g15v_clrMask

            LDY #$00
        _g15v_loop:
            LDA (_gfx_zp_ptr),Y
            AND _g15v_clrMask
            ORA _g15v_orMask
            STA (_gfx_zp_ptr),Y
            ; ptr += 40 (next row)
            CLC
            LDA _gfx_zp_ptr
            ADC #$28
            STA _gfx_zp_ptr
            BCC _g15v_no_carry2
            INC _gfx_zp_ptr+1
        _g15v_no_carry2:
            ; 16-bit countdown
            LDA _g15v_cntLo
            BNE _g15v_dec
            LDA _g15v_cntHi
            BEQ _g15v_done
            DEC _g15v_cntHi
        _g15v_dec:
            DEC _g15v_cntLo
            LDA _g15v_cntLo
            ORA _g15v_cntHi
            BNE _g15v_loop
        _g15v_done:
        }
        return;
        }
    }
