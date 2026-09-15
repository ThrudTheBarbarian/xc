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

// Gfx6.xc - GR.6 (160x96 2-colour) primitives for the Gfx master class.
//
// Memory layout:
//   - Screen RAM is 160*96/8 = 1920 bytes at sbase.
//   - Each row is 20 bytes (160 px / 8 pixels per byte).
//   - Pixel at (x, y) lives in byte sbase + y*20 + (x>>3),
//     bit position $80 >> (x & 7) (high bit = leftmost pixel).
//
// 2-colour (1bpp). pen = 1 sets the pixel (foreground), pen = 0 clears
// it (background). The on-screen colours are controlled via COLPF0 /
// COLPF1 ($D016/$D017) -- set them externally to pick the visible
// foreground/background hues.
//
// ANTIC mode 6 ($06): 160 pixels/row, 1bpp, 96 rows. Each byte holds
// 8 pixels. Row stride = 20 bytes. Total screen = 1920 bytes, well
// within a single ANTIC 4 KB fetch boundary, so one LMS is enough.
//
// Display list layout (105 bytes, shares sbase start):
//   3x $70       24 blank scanlines (top margin)
//   $46 + addr   LMS mode 6 at sbase ($8000)
//   96x $06      96 mode-6 lines
//   $41 + addr   JVB back to DL start ($8000)
//
// The DL overlaps the first 105 bytes of the screen buffer (same
// approach as Gfx7). setupNative() copies the DL, points ANTIC at it,
// and clears the screen before the first frame renders.

#import "Stdio.xc"
#import "Gfx.xc"

// Y-row offset tables: y*20 for y in 0..95.
// y*20 fits in a u16; separate lo/hi tables for the asm codegen paths.
u8 _gfx6_yLo[96];
u8 _gfx6_yHi[96];

// GR.6 display list (ANTIC mode 6 = $06, 2 colours, 160x96).
// 24 BLANK scanlines + 96 mode-6 rows + JVB back to start.
// 105 bytes total. The LMS at the top targets $8000; all 1920 screen
// bytes fit in one ANTIC 4 KB fetch boundary ($8000-$877F), so no
// second LMS is required.
u8 _gfx6_dlist[105] = {
    $70, $70, $70,                                    // 3 BLANK (24 scanlines)
    $46, $00, $80,                                    // LMS mode 6 at $8000
    $06, $06, $06, $06, $06, $06, $06, $06, $06, $06, // 10
    $06, $06, $06, $06, $06, $06, $06, $06, $06, $06, // 20
    $06, $06, $06, $06, $06, $06, $06, $06, $06, $06, // 30
    $06, $06, $06, $06, $06, $06, $06, $06, $06, $06, // 40
    $06, $06, $06, $06, $06, $06, $06, $06, $06, $06, // 50
    $06, $06, $06, $06, $06, $06, $06, $06, $06, $06, // 60
    $06, $06, $06, $06, $06, $06, $06, $06, $06, $06, // 70
    $06, $06, $06, $06, $06, $06, $06, $06, $06, $06, // 80
    $06, $06, $06, $06, $06, $06, $06, $06, $06, $06, // 90
    $06, $06, $06, $06, $06, $06,                     // 96
    $41, $00, $80                                     // JVB target $8000
};

// Bit set mask: setMask[i] isolates bit i (MSB = leftmost = bit 7).
// Used by getPixel and as the ORA mask base for pen=1 plot.
u8 _gfx6_setMask[8] = {$80, $40, $20, $10, $08, $04, $02, $01};

// andTable / orTable for branchless plot. Indexed by (pen & 1) * 8 + (x & 7).
// pen=0: AND with clear mask (0 → bitmap position)
//        OR with $00 (no bits to set)
// pen=1: AND with $FF (no-op -- keep all bits)
//        OR with set mask
//
// Layout: pen=0 (indices 0-7) then pen=1 (indices 8-15). Each half is 8 bytes.
u8 _gfx6_andTable[16] = {
    $7F, $BF, $DF, $EF, $F7, $FB, $FD, $FE, // pen=0: clear selected bit
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF  // pen=1: keep all bits
};
u8 _gfx6_orTable[16] = {
    $00, $00, $00, $00, $00, $00, $00, $00, // pen=0: no bits to set
    $80, $40, $20, $10, $08, $04, $02, $01  // pen=1: set selected bit
};

// hline range-mask tables for the bulk-byte fast path.
// Indexed by bit-within-byte (lo or hi end of the line):
//   hLeftSet[bitLo]  : bits bitLo..7 (rightward of bitLo) set
//                       -> ORA mask for the leftmost byte when pen = 1.
//   hLeftClr[bitLo]  : NOT hLeftSet[bitLo]
//                       -> AND mask for the leftmost byte when pen = 0.
//   hRightSet[bitHi] : bits 0..bitHi set
//   hRightClr[bitHi] : NOT hRightSet[bitHi]
u8 _gfx6_hLeftSet[8] = {$FF, $7F, $3F, $1F, $0F, $07, $03, $01};
u8 _gfx6_hLeftClr[8] = {$00, $80, $C0, $E0, $F0, $F8, $FC, $FE};
u8 _gfx6_hRightSet[8] = {$80, $C0, $E0, $F0, $F8, $FC, $FE, $FF};
u8 _gfx6_hRightClr[8] = {$7F, $3F, $1F, $0F, $07, $03, $01, $00};

u8 _gfx6_ready = 0;

// Build the y*20 lookup tables for y in 0..95.
void _gfx6_buildTables(void)
    {
    if (_gfx6_ready != 0)
        {
        return;
        }
    u16 acc = 0;
    u8 i = 0;
    while (i < 96)
        {
        _gfx6_yLo[i] = (u8)(acc & $FF);
        _gfx6_yHi[i] = (u8)(acc >> 8);
        acc = acc + 20;
        i = i + 1;
        }
    _gfx6_ready = 1;
    return;
    }

class Gfx6 : Gfx
    {
    // Zero-arg init: reads screen base from SAVMSC after a
    // GRAPHICS 6 command has been issued via Gfx.setMode(6).
    void init(void)
        {
        readFromOS();
        at.x = 0;
        at.y = 0;
        pen = 1;
        fillColor = 0;
        clearBytes = 1920;
        _width = 160;
        _height = 96;
        if (_gfx6_ready == 0)
            {
            _gfx6_buildTables();
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
        clearBytes = 1920;
        _width = 160;
        _height = 96;
        if (_gfx6_ready == 0)
            {
            _gfx6_buildTables();
            }
        return;
        }

    // Update the screen base post-construction.
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

    // Set up GR.6 without going through the OS GRAPHICS 6 command.
    // Places the display list at $8000 and the screen buffer at $8000
    // (first 105 bytes overlap with the DL, cleared on the first
    // draw) so programs that allocate a heap buffer separately should
    // use init(u8* buf) instead.
    void setupNative(void)
        {
        sbase = $8000;
        clearBytes = 1920;
        _width = 160;
        _height = 96;
        if (_gfx6_ready == 0)
            {
            _gfx6_buildTables();
            }
        asm
        {
            SEI
            ; Copy DL to $8000. The 105-byte dlist already has the
            ; LMS target ($8000) and JVB target ($8000) baked into
            ; its initialiser, so a straight copy is enough -- no
            ; runtime patch needed.
            LDA #<_gfx6_dlist
            STA $B0
            LDA #>_gfx6_dlist
            STA $B1
            LDA #$00
            STA $B2
            LDA #$80
            STA $B3
            LDX #105
            LDY #$00
        _gfx6_dl_copy:
            LDA ($B0),Y
            STA ($B2),Y
            INY
            DEX
            BNE _gfx6_dl_copy

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

    // Plot a single pixel at (x, y) using pen (0 or 1).
    // Branchless implementation using andTable/orTable indexed by
    // (pen & 1) * 8 + (x & 7). Bounds-checks; off-screen plots are
    // no-ops.
    //
    // ZP layout: locals use `_g6p_` prefix for slot uniqueness
    // across inline:plot expansions (same convention as Gfx8's _g8p_).
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

        u16 _g6p_ux = (u16)x;
        u8 _g6p_uy = (u8)y;
        u8 _g6p_c = pen;
        u16 _g6p_sb = sbase;
        u8 _g6p_sbk = sbank;
        u16 _gfx_zp_ptr;
        u8 _g6p_idx;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; access below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g6p_sbk
            STA __bank_data_reg
            ; ptr = sbase + yTable[y]
            LDY _g6p_uy
            CLC
            LDA _g6p_sb
            ADC _gfx6_yLo,Y
            STA _gfx_zp_ptr
            LDA _g6p_sb+1
            ADC _gfx6_yHi,Y
            STA _gfx_zp_ptr+1
            ; byte offset within row = x >> 3
            LDA _g6p_ux+1
            LSR A
            LDA _g6p_ux
            ROR A
            LSR A
            LSR A                    ; A = x>>3 (0..19)
            TAY
            ; index = (pen & 1) * 8 + (x & 7)
            LDA _g6p_c
            AND #$01
            ASL A
            ASL A
            ASL A
            STA _g6p_idx
            LDA _g6p_ux
            AND #$07
            ORA _g6p_idx
            TAX
            LDA (_gfx_zp_ptr),Y
            AND _gfx6_andTable,X
            ORA _gfx6_orTable,X
            STA (_gfx_zp_ptr),Y
        }
        return;
        }

    // Read a pixel at (x, y). Returns 1 (set) or 0 (clear).
    // Off-screen reads return 0.
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

        u16 _g6g_ux = (u16)x;
        u8 _g6g_uy = (u8)y;
        u16 _g6g_sb = sbase;
        u8 _g6g_sbk = sbank;
        u16 _gfx_zp_ptr;
        u8 result;
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; read below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g6g_sbk
            STA __bank_data_reg
            ; ptr = sbase + yTable[y]
            LDY _g6g_uy
            CLC
            LDA _g6g_sb
            ADC _gfx6_yLo,Y
            STA _gfx_zp_ptr
            LDA _g6g_sb+1
            ADC _gfx6_yHi,Y
            STA _gfx_zp_ptr+1
            ; ptr += (x >> 3)
            LDA _g6g_ux+1
            LSR A
            LDA _g6g_ux
            ROR A
            LSR A
            LSR A
            CLC
            ADC _gfx_zp_ptr
            STA _gfx_zp_ptr
            BCC _g6g_no_carry
            INC _gfx_zp_ptr+1
        _g6g_no_carry:
            ; mask = setMask[x & 7], then AND with byte
            LDA _g6g_ux
            AND #$07
            TAX
            LDA _gfx6_setMask,X
            LDY #$00
            AND (_gfx_zp_ptr),Y
            ; branchless coerce to 0/1: CPX with A sets C iff A >= 1;
            ; ADC #0 deposits C into A which started at 0.
            TAX
            LDA #$00
            CPX #$01
            ADC #$00
            STA result
        }
        return result;
        }

    // Horizontal line from x0 to x1 at row y. Bulk-byte fast path:
    // split into left-partial / middle full-byte run / right-partial,
    // with mask-table reads driving the partials and straight
    // STA #$FF / #$00 driving the middle bytes.
    //
    // Cost: ~25 cycles per middle byte (8 pixels) + ~50 cycles for
    // each edge byte. A 160-wide line runs in ~0.5ms vs ~11ms for
    // the per-pixel inline:plot fallback.
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

        u16 _g6h_lo = (u16)lo;
        u16 _g6h_hi = (u16)hi;
        u8 _g6h_y = (u8)y;
        u8 _g6h_p = pen;
        u16 _g6h_sb = sbase;
        u8 _g6h_sbk = sbank;

        u16 _gfx_zp_ptr;
        u8 _g6h_bL;  // byte index of leftmost touched byte
        u8 _g6h_bR;  // byte index of rightmost touched byte
        u8 _g6h_iL;  // bit index within bL (0..7)
        u8 _g6h_iR;  // bit index within bR (0..7)
        u8 _g6h_msk; // scratch mask byte
        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; writes below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g6h_sbk
            STA __bank_data_reg
            ; ptr = sbase + yTable[y].
            LDY _g6h_y
            CLC
            LDA _g6h_sb
            ADC _gfx6_yLo,Y
            STA _gfx_zp_ptr
            LDA _g6h_sb+1
            ADC _gfx6_yHi,Y
            STA _gfx_zp_ptr+1

            ; byteL = lo >> 3, iL = lo & 7.
            LDA _g6h_lo+1
            LSR A
            LDA _g6h_lo
            ROR A
            LSR A
            LSR A
            STA _g6h_bL
            LDA _g6h_lo
            AND #$07
            STA _g6h_iL

            ; byteR = hi >> 3, iR = hi & 7.
            LDA _g6h_hi+1
            LSR A
            LDA _g6h_hi
            ROR A
            LSR A
            LSR A
            STA _g6h_bR
            LDA _g6h_hi
            AND #$07
            STA _g6h_iR

            ; Branch on pen: pen=1 sets bits via OR, pen=0 clears via AND.
            LDA _g6h_p
            BEQ _g6h_clr
            ; ---- pen = 1, set bits ----
            ; Single-byte case: byteL == byteR.
            LDA _g6h_bL
            CMP _g6h_bR
            BNE _g6h_set_multi
            LDX _g6h_iL
            LDA _gfx6_hLeftSet,X
            LDX _g6h_iR
            AND _gfx6_hRightSet,X
            LDY _g6h_bL
            ORA (_gfx_zp_ptr),Y
            STA (_gfx_zp_ptr),Y
            JMP _g6h_done
        _g6h_set_multi:
            ; Left partial (byteL): OR with hLeftSet[bitL].
            LDX _g6h_iL
            LDY _g6h_bL
            LDA (_gfx_zp_ptr),Y
            ORA _gfx6_hLeftSet,X
            STA (_gfx_zp_ptr),Y
            ; Middle bytes: bL+1 .. bR-1, each byte = $FF.
            ; Count = bR - bL - 1; BEQ skips when adjacent.
            INY
            LDA _g6h_bR
            SEC
            SBC _g6h_bL
            SEC
            SBC #$01
            TAX
            BEQ _g6h_set_right
            LDA #$FF
        _g6h_set_mid:
            STA (_gfx_zp_ptr),Y
            INY
            DEX
            BNE _g6h_set_mid
        _g6h_set_right:
            ; Right partial (byteR): OR with hRightSet[bitR].
            LDX _g6h_iR
            LDA _gfx6_hRightSet,X
            LDY _g6h_bR
            ORA (_gfx_zp_ptr),Y
            STA (_gfx_zp_ptr),Y
            JMP _g6h_done
            ; ---- pen = 0, clear bits ----
        _g6h_clr:
            ; Single-byte case: byteL == byteR.
            ; mask = hLeftSet[bitL] AND hRightSet[bitR]; clear = NOT mask.
            LDA _g6h_bL
            CMP _g6h_bR
            BNE _g6h_clr_multi
            LDX _g6h_iL
            LDA _gfx6_hLeftSet,X
            LDX _g6h_iR
            AND _gfx6_hRightSet,X
            EOR #$FF                  ; A = clear mask
            LDY _g6h_bL
            AND (_gfx_zp_ptr),Y
            STA (_gfx_zp_ptr),Y
            JMP _g6h_done
        _g6h_clr_multi:
            ; Left partial: AND hLeftClr[bitL] with the byte.
            LDX _g6h_iL
            LDY _g6h_bL
            LDA (_gfx_zp_ptr),Y
            AND _gfx6_hLeftClr,X
            STA (_gfx_zp_ptr),Y
            ; Middle bytes: store $00.
            INY
            LDA _g6h_bR
            SEC
            SBC _g6h_bL
            SEC
            SBC #$01
            TAX
            BEQ _g6h_clr_right
            LDA #$00
        _g6h_clr_mid:
            STA (_gfx_zp_ptr),Y
            INY
            DEX
            BNE _g6h_clr_mid
        _g6h_clr_right:
            ; Right partial: AND hRightClr[bitR] with the byte.
            LDX _g6h_iR
            LDA _gfx6_hRightClr,X
            LDY _g6h_bR
            AND (_gfx_zp_ptr),Y
            STA (_gfx_zp_ptr),Y
        _g6h_done:
        }
        return;
        }

    // Vertical line at column x from y0 to y1. Same bulk-byte
    // approach as Gfx8.vline: one AND/OR per row with ADC #20
    // to advance to the next row. ~30 cycles per row vs ~150 for
    // per-pixel inline:plot.
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

        u16 _gfx_zp_ptr;
        u8 _gfx_zp_mask;
        u16 _g6v_count = (u16)(y1 - y0 + 1);
        u8 _g6v_cntLo = (u8)(_g6v_count & $FF);
        u8 _g6v_cntHi = (u8)(_g6v_count >> 8);
        u16 _g6v_sb = sbase;
        u16 _g6v_ux = (u16)x;
        u8 _g6v_uy0 = (u8)y0;
        u8 _g6v_pen = pen;
        u8 _g6v_sbk = sbank;

        asm
        {
            ; Select the screen buffer's data bank before the indirect
            ; writes below (private:docs/bugs/007); lookup tables are unbanked.
            LDA _g6v_sbk
            STA __bank_data_reg
            ; ptr = sbase + yTable[y0] + (x >> 3)
            LDY _g6v_uy0
            CLC
            LDA _g6v_sb
            ADC _gfx6_yLo,Y
            STA _gfx_zp_ptr
            LDA _g6v_sb+1
            ADC _gfx6_yHi,Y
            STA _gfx_zp_ptr+1
            LDA _g6v_ux+1
            LSR A
            LDA _g6v_ux
            ROR A
            LSR A
            LSR A
            CLC
            ADC _gfx_zp_ptr
            STA _gfx_zp_ptr
            LDA _gfx_zp_ptr+1
            ADC #$00
            STA _gfx_zp_ptr+1
            ; mask = setMask[x & 7]
            LDA _g6v_ux
            AND #$07
            TAX
            LDA _gfx6_setMask,X
            STA _gfx_zp_mask
            ; pen branch
            LDA _g6v_pen
            BEQ _g6v_loop0
            ; pen=1: ORA mask into (ptr),Y; advance row by 20.
            LDY #$00
        _g6v_loop:
            LDA _gfx_zp_mask
            ORA (_gfx_zp_ptr),Y
            STA (_gfx_zp_ptr),Y
            ; ptr += 20 (next row)
            CLC
            LDA _gfx_zp_ptr
            ADC #$14
            STA _gfx_zp_ptr
            BCC _g6v_lo_done
            INC _gfx_zp_ptr+1
        _g6v_lo_done:
            ; 16-bit countdown
            LDA _g6v_cntLo
            BNE _g6v_dec
            LDA _g6v_cntHi
            BEQ _g6v_done
            DEC _g6v_cntHi
        _g6v_dec:
            DEC _g6v_cntLo
            LDA _g6v_cntLo
            ORA _g6v_cntHi
            BNE _g6v_loop
            JMP _g6v_done
        _g6v_loop0:
            ; pen=0: AND inverted mask into (ptr),Y; advance row by 20.
            LDA _gfx_zp_mask
            EOR #$FF
            STA _gfx_zp_mask
            LDY #$00
        _g6v_loop0_top:
            LDA _gfx_zp_mask
            AND (_gfx_zp_ptr),Y
            STA (_gfx_zp_ptr),Y
            CLC
            LDA _gfx_zp_ptr
            ADC #$14
            STA _gfx_zp_ptr
            BCC _g6v_lo_done0
            INC _gfx_zp_ptr+1
        _g6v_lo_done0:
            LDA _g6v_cntLo
            BNE _g6v_dec0
            LDA _g6v_cntHi
            BEQ _g6v_done
            DEC _g6v_cntHi
        _g6v_dec0:
            DEC _g6v_cntLo
            LDA _g6v_cntLo
            ORA _g6v_cntHi
            BNE _g6v_loop0_top
        _g6v_done:
        }
        return;
        }
    }
