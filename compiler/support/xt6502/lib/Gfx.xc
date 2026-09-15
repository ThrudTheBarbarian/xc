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

// Gfx.xc — graphics master class shared across all GR.N modes.
//
// Holds drawing-state ivars (screen base, current point "here",
// draw / fill colour) and higher-level routines (line, rect,
// circle, fill, flood-fill, …) that build on the per-mode
// primitives plot/hline/getPixel.
//
// Per-mode subclasses (Gfx8 for GR.8 1bpp, Gfx15 for GR.15 2bpp,
// etc.) override just the primitives. The shared higher-level
// routines call those overrides via `inline:plot(...)` /
// `inline:self.hline(...)` / `inline:self.getPixel(...)` —
// transitive devirtualisation guarantees that an
// `inline:gfx8.line(...)` call site pastes Gfx.line's body AND
// substitutes Gfx8's plot at every per-pixel call.
//
// Without inline:, calls to the master's higher-level routines
// virtual-dispatch the primitive once per pixel — too slow for
// real-time graphics. Use `inline:` for hot paths; plain
// non-inline calls are fine for one-off setup work where the
// JSR overhead doesn't matter.
//
// Memory note: the screen base is held as a 16-bit address. For
// xe banked-screen layouts (e.g. an xe:* mode where the screen
// buffer lives in a switched-in bank rather than fixed at $8000),
// the per-mode subclass needs to drive PORTB around its primitive
// emits. The base class is bank-agnostic.

#import "Stdio.xc"

// Atari graphics mode constants. Match the BASIC GRAPHICS N
// numbering. Useful for code clarity at call sites:
//   Gfx.setMode(GFX_GR8);   // 320x192 1bpp
//   Gfx.setMode(GFX_GR7);   // 160x96 4-colour
#define GFX_GR0 0   // 40x24 text
#define GFX_GR1 1   // 20x24 large text, 5 colours
#define GFX_GR2 2   // 20x12 huge text, 5 colours
#define GFX_GR3 3   // 40x24 4-colour
#define GFX_GR4 4   // 80x48 mono
#define GFX_GR5 5   // 80x48 4-colour
#define GFX_GR6 6   // 160x96 mono
#define GFX_GR7 7   // 160x96 4-colour
#define GFX_GR8 8   // 320x192 1bpp
#define GFX_GR9 9   // 80x192 16-luminance (GTIA)
#define GFX_GR10 10 // 80x192 9-colour (GTIA)
#define GFX_GR11 11 // 80x192 16-colour (GTIA)
#define GFX_GR15 15 // 160x192 4-colour (ANTIC mode E)

// Resolution-by-name aliases for use with the gfxCreate() factory
// in GfxFactory.xc.
// `GFX_<w>_<h>_<b>` — width × height pixels, b bits per pixel.
// One alias per Atari graphics mode (GR.0..GR.11, GR.15). Some
// modes share dimensions and bit depth; they map to the same
// constant since the factory's selector is the OS mode number,
// not the descriptive name.
#define GFX_40_24_2 GFX_GR3
#define GFX_80_48_1 GFX_GR4
#define GFX_80_48_2 GFX_GR5
#define GFX_160_96_1 GFX_GR6
#define GFX_160_96_2 GFX_GR7
#define GFX_320_192_1 GFX_GR8
#define GFX_80_192_4 GFX_GR9 // also GR.10 / GR.11
#define GFX_160_192_2 GFX_GR15

// Device name "S:" + EOL ($9B) for the CIO open. Declared as a
// file-scope global so the optimiser doesn't drop it — defining
// the bytes inline inside `setMode`'s asm block via .byte after
// a JMP makes the optimiser at -O3 think the data is unreachable
// code and prune both the .byte directives and the label,
// leaving the LDA #<_gfx_dev_S references dangling.
u8 _gfx_dev_S[3] = {$53, $3A, $9B};

// Auto-restore-on-exit flag. Set to 1 by Gfx.setMode() the first
// time it changes the screen mode; consulted by the runtime's
// post-`_fn_main` exit hook (`Gfx.atExit()` below). Programs that
// never call setMode (and therefore never override the OS-managed
// GR.0 screen) leave the flag at 0 and the exit hook is a no-op.
//
// File-scope global so a single static byte covers every program;
// no per-instance overhead. Reachability-trim friendly: if the
// program never calls setMode the flag is dead and gets stripped
// (along with the rest of Gfx).
u8 _gfx_mode_changed = $00;

// Plain (x, y) screen coordinate. Signed because off-screen
// arithmetic in higher-level routines (clipping, line stepping)
// can briefly leave the bounds; clamping happens at the per-mode
// primitives (plot/hline/vline) which check before writing the
// screen byte. Used as the value type wherever the API talks
// about points — `g.at` is the current pen position, moveTo/
// lineTo/bezierTo accept a Point, etc.
struct Point
    {
    i16 x;
    i16 y;
    }

    // floodFill seed-queue ring buffer. 256 entries, (u16 x, u8 y) per
    // entry = 3 bytes/entry, 768 bytes total. head and tail are u8 so
    // the modulo-256 wrap is implicit; count is a u16 because it reaches
    // exactly 256 when the buffer is full and 0 when empty. Frontier is
    // dropped silently on overflow — floodFill returns false so callers
    // can re-seed an unfilled region.
    //
    // Buffers are heap-allocated lazily on the first floodFill call
    // rather than declared as static arrays, so programs that never call
    // floodFill don't pay for the 768 bytes in their binary. Allocations
    // leak (no destructor) — acceptable for typical single-instance
    // programs where the heap is reclaimed on exit.
    u8* _gfx_ff_xLo;
u8* _gfx_ff_xHi;
u8* _gfx_ff_ys;
u8 _gfx_ff_head;
u8 _gfx_ff_tail;
u16 _gfx_ff_count;
bool _gfx_ff_ovf;

// 256-entry sin LUT: sinTable[t] = round(128 + 127 * sin(t * 2π / 256))
// Range 1-255, subtract 128 to recover signed sin * 127.
u8 _gfx_sinTable[256] = {
    128,
    131,
    134,
    137,
    140,
    144,
    147,
    150,
    153,
    156,
    159,
    162,
    165,
    168,
    171,
    174,
    177,
    179,
    182,
    185,
    188,
    191,
    193,
    196,
    199,
    201,
    204,
    206,
    209,
    211,
    213,
    216,
    218,
    220,
    222,
    224,
    226,
    228,
    230,
    232,
    234,
    235,
    237,
    239,
    240,
    241,
    243,
    244,
    245,
    246,
    248,
    249,
    250,
    250,
    251,
    252,
    253,
    253,
    254,
    254,
    254,
    255,
    255,
    255,
    255,
    255,
    255,
    255,
    254,
    254,
    254,
    253,
    253,
    252,
    251,
    250,
    250,
    249,
    248,
    246,
    245,
    244,
    243,
    241,
    240,
    239,
    237,
    235,
    234,
    232,
    230,
    228,
    226,
    224,
    222,
    220,
    218,
    216,
    213,
    211,
    209,
    206,
    204,
    201,
    199,
    196,
    193,
    191,
    188,
    185,
    182,
    179,
    177,
    174,
    171,
    168,
    165,
    162,
    159,
    156,
    153,
    150,
    147,
    144,
    140,
    137,
    134,
    131,
    128,
    125,
    122,
    119,
    116,
    112,
    109,
    106,
    103,
    100,
    97,
    94,
    91,
    88,
    85,
    82,
    79,
    77,
    74,
    71,
    68,
    65,
    63,
    60,
    57,
    55,
    52,
    50,
    47,
    45,
    43,
    40,
    38,
    36,
    34,
    32,
    30,
    28,
    26,
    24,
    22,
    21,
    19,
    17,
    16,
    15,
    13,
    12,
    11,
    10,
    8,
    7,
    6,
    6,
    5,
    4,
    3,
    3,
    2,
    2,
    2,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    2,
    2,
    2,
    3,
    3,
    4,
    5,
    6,
    6,
    7,
    8,
    10,
    11,
    12,
    13,
    15,
    16,
    17,
    19,
    21,
    22,
    24,
    26,
    28,
    30,
    32,
    34,
    36,
    38,
    40,
    43,
    45,
    47,
    50,
    52,
    55,
    57,
    60,
    63,
    65,
    68,
    71,
    74,
    77,
    79,
    82,
    85,
    88,
    91,
    94,
    97,
    100,
    103,
    106,
    109,
    112,
    116,
    119,
    122,
    125,
};

// Integer square root (floor) — sum-of-odd-numbers method.
// Only uses addition, subtraction, and comparison.
// For n ≤ 10000, at most 100 iterations.
i16 _isqrt(i16 n)
    {
    if (n <= 0)
        return 0;
    i16 res = 0;
    i16 odd = 1;
    while (n >= odd)
        {
        n = n - odd;
        res = res + 1;
        odd = odd + 2;
        }
    return res;
    }

class Gfx
    {
    u16 sbase;
    u8 sbank; // data bank of the screen buffer (0 = main RAM / a
              // fixed OS screen outside the $A000-$CFFF window; >0
              // when sbase points into a banked heap buffer, e.g.
              // `new Gfx8(new u8[7680])`). The asm primitives address
              // sbase as a flat 16-bit pointer, so they must select
              // this bank before touching the window. See private:docs/bugs/007.
    Point at; // current pen position
    u8 pen;   // bit polarity for stroke draws (plot, line,
              // hline, etc.). In 1bpp modes 0/1 selects the
              // background or foreground bit. The on-screen
              // colour is set separately via the per-mode
              // OS shadow registers (COLOR0..COLOR4).
    u8 fillColor;
    u16 clearBytes; // bytes the clear() loop walks from sbase —
                    // set by each subclass.init() to the
                    // mode-specific screen size (3840 for GR.7,
                    // 7680 for GR.8 full-screen, less for split
                    // displays that preserve text rows).
    u16 _width;     // screen width in pixels, set by subclass init
    u16 _height;    // screen height in pixels, set by subclass init

    // Default no-op primitives — concrete subclasses override.
    // Kept non-empty so the inliner has a body to paste; an
    // unoverridden mode that ends up calling these draws nothing,
    // matching the "set the mode first" usage contract.
    void plot(i16 x, i16 y)
        {
        return;
        }

    u8 getPixel(i16 x, i16 y)
        {
        return 0;
        }

    void hline(i16 x0, i16 x1, i16 y)
        {
        return;
        }

    // Vertical line stub — overridden by subclasses with a
    // bulk-byte path (see Gfx6.vline, Gfx8.vline, etc.).
    void vline(i16 x, i16 y0, i16 y1)
        {
        return;
        }

    // Clear the screen-buffer region the receiver owns to its
    // current `fillColor`. Walks `clearBytes` bytes from `sbase`
    // writing $00 (fillColor 0) or $FF (any other) so a single
    // body covers every Gfx subclass — Gfx8 with clearBytes =
    // 7680 for full GR.8, Gfx8 split-display with clearBytes =
    // gr8Lines * 40, Gfx7 with clearBytes = 3840 for GR.7. The
    // byte interpretation is mode-dependent: 1bpp modes get
    // pure-black or pure-white, 2bpp modes get colour 0 or
    // colour 3 (since $FF replicates the high colour into all
    // four pixel slots). Subclasses that need a finer-grained
    // fill (e.g. fillColor 2 in GR.7) can still override this
    // method with a per-mode body.
    void clear(void)
        {
        u8 fill;
        if (fillColor == 0)
            {
            fill = $00;
            }
        else
            {
            fill = $FF;
            }
        u16 sb = sbase;
        u16 cb = clearBytes;
        u8 pages = (u8)(cb >> 8);
        u8 tail = (u8)(cb & $FF);
        u8 sbk = sbank;
        asm
        {
            ; Select the screen buffer's data bank (0 = main RAM / fixed OS
            ; screen, harmless; >0 = banked heap buffer). The flat ($B0),Y
            ; writes below only see the right bytes when __bank_data_reg
            ; matches the buffer's bank (private:docs/bugs/007).
            LDA sbk
            STA __bank_data_reg
            LDA sb
            STA $B0
            LDA sb+1
            STA $B1
            LDA fill
            LDX pages
            BEQ _gfx_clr_tail
            LDY #$00
        _gfx_clr_page:
            STA ($B0),Y
            INY
            BNE _gfx_clr_page
            INC $B1
            DEX
            BNE _gfx_clr_page
        _gfx_clr_tail:
            LDX tail
            BEQ _gfx_clr_done
            LDY #$00
        _gfx_clr_tail_lp:
            STA ($B0),Y
            INY
            DEX
            BNE _gfx_clr_tail_lp
        _gfx_clr_done:
        }
        return;
        }

    // Set/get state.
    void setPen(u8 c)
        {
        pen = c;
        return;
        }
    void setFillColor(u8 c)
        {
        fillColor = c;
        return;
        }
    void moveTo(i16 x, i16 y)
        {
        at.x = x;
        at.y = y;
        return;
        }
    void moveTo(Point p)
        {
        at.x = p.x;
        at.y = p.y;
        return;
        }
    Point currentPoint(void)
        {
        return at;
        }
    i16 currentX(void)
        {
        return at.x;
        }
    i16 currentY(void)
        {
        return at.y;
        }

    // ── Higher-level drawing methods ──────────────────────────
    // These build on the per-mode primitives (plot, hline, vline,
    // getPixel) via virtual dispatch so they work with any subclass.
    // Callers who need maximum speed should use the inline: prefix:
    //     inline:self.circle(cx, cy, r);
    // The transitive inliner will devirtualise and paste the
    // concrete subclass's plot body at each pixel.

    // Filled rectangle via hline scanlines.
    void fillRect(i16 x0, i16 y0, i16 x1, i16 y1)
        {
        i16 yy = y0;
        while (yy <= y1)
            {
            inline : hline(x0, x1, yy);
            yy = yy + 1;
            }
        return;
        }

    // Circle outline using Bresenham 8-octant.
    void circle(i16 cx, i16 cy, i16 r)
        {
        if (r < 0)
            {
            r = -r;
            }
        if (r == 0)
            {
            inline : plot(cx, cy);
            return;
            }

        i16 x = 0;
        i16 y = r;
        i16 d = 3 - 2 * r;
        while (x <= y)
            {
            inline : plot(cx + x, cy + y);
            inline : plot(cx - x, cy + y);
            inline : plot(cx + x, cy - y);
            inline : plot(cx - x, cy - y);
            inline : plot(cx + y, cy + x);
            inline : plot(cx - y, cy + x);
            inline : plot(cx + y, cy - x);
            inline : plot(cx - y, cy - x);
            if (d > 0)
                {
                y = y - 1;
                d = d + 4 * (x - y) + 10;
                }
            else
                {
                d = d + 4 * x + 6;
                }
            x = x + 1;
            }
        return;
        }

    // Filled disk via hline scanlines.
    void fillCircle(i16 cx, i16 cy, i16 r)
        {
        if (r < 0)
            {
            r = -r;
            }
        if (r == 0)
            {
            inline : plot(cx, cy);
            return;
            }

        i16 x = 0;
        i16 y = r;
        i16 d = 3 - 2 * r;
        while (x <= y)
            {
            inline : hline(cx - y, cx + y, cy + x);
            if (x != 0)
                {
                inline : hline(cx - y, cx + y, cy - x);
                }
            if (d > 0)
                {
                if (x != y)
                    {
                    inline : hline(cx - x, cx + x, cy + y);
                    inline : hline(cx - x, cx + x, cy - y);
                    }
                y = y - 1;
                d = d + 4 * (x - y) + 10;
                }
            else
                {
                d = d + 4 * x + 6;
                }
            x = x + 1;
            }
        return;
        }

    // Arc outline — gated by quadrant mask (same scheme as Gfx7).
    void arc(i16 cx, i16 cy, i16 r, u8 quadrants)
        {
        if (r < 0)
            {
            r = -r;
            }
        if (quadrants == 0)
            {
            return;
            }
        if (r == 0)
            {
            inline : plot(cx, cy);
            return;
            }

        i16 x = 0;
        i16 y = r;
        i16 d = 3 - 2 * r;
        while (x <= y)
            {
            if ((quadrants & $08) != 0)
                {
                inline : plot(cx + x, cy + y);
                inline : plot(cx + y, cy + x);
                }
            if ((quadrants & $04) != 0)
                {
                inline : plot(cx - x, cy + y);
                inline : plot(cx - y, cy + x);
                }
            if ((quadrants & $01) != 0)
                {
                inline : plot(cx + x, cy - y);
                inline : plot(cx + y, cy - x);
                }
            if ((quadrants & $02) != 0)
                {
                inline : plot(cx - x, cy - y);
                inline : plot(cx - y, cy - x);
                }
            if (d > 0)
                {
                y = y - 1;
                d = d + 4 * (x - y) + 10;
                }
            else
                {
                d = d + 4 * x + 6;
                }
            x = x + 1;
            }
        return;
        }

    // Filled arc — hline-based disk fill gated by quadrant mask.
    void fillArc(i16 cx, i16 cy, i16 r, u8 quadrants)
        {
        if (r < 0)
            {
            r = -r;
            }
        if (quadrants == 0)
            {
            return;
            }
        if (r == 0)
            {
            inline : plot(cx, cy);
            return;
            }

        i16 x = 0;
        i16 y = r;
        i16 d = 3 - 2 * r;
        while (x <= y)
            {
            if ((quadrants & $08) != 0)
                {
                inline : hline(cx, cx + y, cy + x);
                }
            if ((quadrants & $04) != 0)
                {
                inline : hline(cx - y, cx, cy + x);
                }
            if (x != 0)
                {
                if ((quadrants & $01) != 0)
                    {
                    inline : hline(cx, cx + y, cy - x);
                    }
                if ((quadrants & $02) != 0)
                    {
                    inline : hline(cx - y, cx, cy - x);
                    }
                }
            if (d > 0)
                {
                if (x != y)
                    {
                    if ((quadrants & $08) != 0)
                        {
                        inline : hline(cx, cx + x, cy + y);
                        }
                    if ((quadrants & $04) != 0)
                        {
                        inline : hline(cx - x, cx, cy + y);
                        }
                    if ((quadrants & $01) != 0)
                        {
                        inline : hline(cx, cx + x, cy - y);
                        }
                    if ((quadrants & $02) != 0)
                        {
                        inline : hline(cx - x, cx, cy - y);
                        }
                    }
                y = y - 1;
                d = d + 4 * (x - y) + 10;
                }
            else
                {
                d = d + 4 * x + 6;
                }
            x = x + 1;
            }
        return;
        }

    // Filled pie — identical to fillArc for quadrant-mask form.
    void fillPie(i16 cx, i16 cy, i16 r, u8 quadrants)
        {
        fillArc(cx, cy, r, quadrants);
        return;
        }

    // Rectangle outline — 2 hlines + 2 vlines.
    void rect(i16 x0, i16 y0, i16 x1, i16 y1)
        {
        inline : hline(x0, x1, y0);
        inline : hline(x0, x1, y1);
        inline : vline(x0, y0, y1);
        inline : vline(x1, y0, y1);
        return;
        }

    // Pie outline — arc plus radial edges where the arc opens
    // along an axis (XOR of adjacent quadrant bits).
    void pie(i16 cx, i16 cy, i16 r, u8 quadrants)
        {
        if (r < 0)
            {
            r = -r;
            }
        if (quadrants == 0)
            {
            return;
            }
        if (r == 0)
            {
            inline : plot(cx, cy);
            return;
            }

        arc(cx, cy, r, quadrants);

        u8 trBit = quadrants & $01;
        u8 tlBit = (quadrants >> 1) & $01;
        u8 blBit = (quadrants >> 2) & $01;
        u8 brBit = (quadrants >> 3) & $01;

        if ((trBit ^ brBit) != 0)
            {
            line(cx, cy, cx + r, cy);
            }
        if ((trBit ^ tlBit) != 0)
            {
            line(cx, cy, cx, cy - r);
            }
        if ((tlBit ^ blBit) != 0)
            {
            line(cx, cy, cx - r, cy);
            }
        if ((blBit ^ brBit) != 0)
            {
            line(cx, cy, cx, cy + r);
            }
        return;
        }

    // Outline ellipse — parametric with 256-entry sin LUT.
    // x = cx + rx·cos(t), y = cy + ry·sin(t) for t in 0..255.
    // Draws line segments between consecutive points when the gap
    // exceeds 1 pixel.  All arithmetic stays in i16 range for 320×200.
    void oval(i16 cx, i16 cy, i16 rx, i16 ry)
        {
        if (rx < 0)
            {
            rx = -rx;
            }
        if (ry < 0)
            {
            ry = -ry;
            }
        if (rx == 0 && ry == 0)
            {
            inline : plot(cx, cy);
            return;
            }
        if (rx == 0)
            {
            inline : vline(cx, cy - ry, cy + ry);
            return;
            }
        if (ry == 0)
            {
            inline : hline(cx - rx, cx + rx, cy);
            return;
            }

        i16 t, cosVal, sinVal, xOff, yOff, px, py;
        i16 prevX = 0;
        i16 prevY = 0;
        for (t = 0; t < 256; t++)
            {
            cosVal = (i16)_gfx_sinTable[(t + 64) & $FF] - 128;
            sinVal = (i16)_gfx_sinTable[t] - 128;
            // Signed rounding: add ±64 for ±0.5 before /128
            if (cosVal >= 0)
                xOff = (rx * cosVal + 64) / 128;
            else
                xOff = (rx * cosVal - 64) / 128;
            if (sinVal >= 0)
                yOff = (ry * sinVal + 64) / 128;
            else
                yOff = (ry * sinVal - 64) / 128;
            px = cx + xOff;
            py = cy + yOff;

            if (t > 0)
                {
                // Fill gaps > 1 pixel with a midpoint
                i16 adx = px - prevX;
                i16 ady = py - prevY;
                if (adx < 0)
                    adx = -adx;
                if (ady < 0)
                    ady = -ady;
                if (adx > 1 || ady > 1)
                    {
                    inline : plot((prevX + px) / 2, (prevY + py) / 2);
                    }
                }
            inline : plot(px, py);
            prevX = px;
            prevY = py;
            }
        }

    // Filled ellipse — scanline + integer sqrt.
    // For each scanline computes the half-width using isqrt and draws
    // an hline.  All arithmetic stays in i16 range for 320×200.
    void fillOval(i16 cx, i16 cy, i16 rx, i16 ry)
        {
        if (rx < 0)
            {
            rx = -rx;
            }
        if (ry < 0)
            {
            ry = -ry;
            }
        if (rx == 0 && ry == 0)
            {
            inline : plot(cx, cy);
            return;
            }
        if (rx == 0)
            {
            inline : vline(cx, cy - ry, cy + ry);
            return;
            }
        if (ry == 0)
            {
            inline : hline(cx - rx, cx + rx, cy);
            return;
            }

        i16 y, hw;
        i16 rySq = ry * ry;
        for (y = 0; y <= ry; y++)
            {
            hw = (rx * _isqrt(rySq - y * y) + ry / 2) / ry;
            if (hw > 0)
                {
                inline : hline(cx - hw, cx + hw, cy + y);
                if (y > 0)
                    {
                    inline : hline(cx - hw, cx + hw, cy - y);
                    }
                }
            else
                {
                inline : plot(cx, cy + y);
                if (y > 0)
                    {
                    inline : plot(cx, cy - y);
                    }
                }
            }
        }

    // Line using Bresenham. Axis-aligned cases route to hline /
    // vline. Subclasses may override this with a faster SMC-based
    // implementation (see Gfx8).
    void line(i16 x0, i16 y0, i16 x1, i16 y1)
        {
        i16 dx = (x1 >= x0) ? (x1 - x0) : (x0 - x1);
        i16 dy = (y1 >= y0) ? (y1 - y0) : (y0 - y1);
        i16 sx = (x1 >= x0) ? 1 : -1;
        i16 sy = (y1 >= y0) ? 1 : -1;

        if (dy == 0)
            {
            inline : hline(x0, x1, y0);
            return;
            }
        if (dx == 0)
            {
            inline : vline(x0, y0, y1);
            return;
            }

        if (sx < 0)
            {
            i16 t = x0;
            x0 = x1;
            x1 = t;
            i16 t2 = y0;
            y0 = y1;
            y1 = t2;
            sx = 1;
            sy = -sy;
            }

        i16 cx = x0;
        i16 cy = y0;
        i16 err;

        if (dx >= dy)
            {
            err = dy + dy - dx - 1;
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
            err = dx + dx - dy - 1;
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

    void lineTo(i16 x, i16 y)
        {
        line(at.x, at.y, x, y);
        at.x = x;
        at.y = y;
        return;
        }

    void lineTo(Point p)
        {
        line(at.x, at.y, p.x, p.y);
        at.x = p.x;
        at.y = p.y;
        return;
        }

    // Quadratic Bezier — fixed 32-step forward-difference.
    void bezier(i16 x0, i16 y0, i16 x1, i16 y1, i16 x2, i16 y2)
        {
        i16 ax = x0 - 2 * x1 + x2;
        i16 bx = 2 * (x1 - x0);
        i16 ay = y0 - 2 * y1 + y2;
        i16 by = 2 * (y1 - y0);

        i32 fx = (i32)x0 << 10;
        i32 fy = (i32)y0 << 10;
        i32 dfx = (i32)ax + ((i32)bx << 5);
        i32 dfy = (i32)ay + ((i32)by << 5);
        i32 d2fx = (i32)ax << 1;
        i32 d2fy = (i32)ay << 1;

        i16 px = x0;
        i16 py = y0;
        u8 k = 0;
        while (k < 32)
            {
            fx = fx + dfx;
            fy = fy + dfy;
            dfx = dfx + d2fx;
            dfy = dfy + d2fy;
            i16 cx = (i16)(fx >> 10);
            i16 cy = (i16)(fy >> 10);
            line(px, py, cx, cy);
            px = cx;
            py = cy;
            k = k + 1;
            }
        at.x = x2;
        at.y = y2;
        return;
        }

    void bezierTo(i16 x1, i16 y1, i16 x2, i16 y2)
        {
        bezier(at.x, at.y, x1, y1, x2, y2);
        return;
        }

    void bezierTo(Point p1, Point p2)
        {
        bezier(at.x, at.y, p1.x, p1.y, p2.x, p2.y);
        return;
        }

    // Flood fill — scanline algorithm. Uses _gfx_ff_* globals for
    // the 256-entry seed queue (heap-allocated lazily on first
    // call). Returns false on overflow.
    bool floodFill(i16 sx, i16 sy)
        {
        if (sx < 0 || (u16)sx >= _width)
            {
            return true;
            }
        if (sy < 0 || (u16)sy >= _height)
            {
            return true;
            }

        u8 seedColor = inline : getPixel(sx, sy);
        u8 newColor = fillColor;
        if (seedColor == newColor)
            {
            return true;
            }

        if (_gfx_ff_xLo == (u8*)0)
            {
            _gfx_ff_xLo = new u8[256];
            _gfx_ff_xHi = new u8[256];
            _gfx_ff_ys = new u8[256];
            }

        _gfx_ff_head = 0;
        _gfx_ff_tail = 0;
        _gfx_ff_count = 0;
        _gfx_ff_ovf = false;

        _gfx_ff_xLo[0] = (u8)((u16)sx & $FF);
        _gfx_ff_xHi[0] = (u8)((u16)sx >> 8);
        _gfx_ff_ys[0] = (u8)sy;
        _gfx_ff_head = 1;
        _gfx_ff_count = 1;

        u8 origPen = pen;
        pen = newColor;

        while (_gfx_ff_count > 0)
            {
            u16 cx = (u16)_gfx_ff_xLo[_gfx_ff_tail] | ((u16)_gfx_ff_xHi[_gfx_ff_tail] << 8);
            u8 cy = _gfx_ff_ys[_gfx_ff_tail];
            _gfx_ff_tail = _gfx_ff_tail + 1;
            _gfx_ff_count = _gfx_ff_count - 1;

            if (inline : getPixel((i16)cx, cy) != seedColor)
                {
                continue;
                }

            i16 xL = (i16)cx;
            while (xL > 0 && inline : getPixel(xL - 1, cy) == seedColor)
                {
                xL = xL - 1;
                }
            i16 xR = (i16)cx;
            while (xR < (i16)(_width - 1) && inline : getPixel(xR + 1, cy) == seedColor)
                {
                xR = xR + 1;
                }

            inline : hline(xL, xR, cy);

            if (cy > 0)
                {
                _ff_scanRow(cy - 1, xL, xR, seedColor);
                }
            if (cy < _height - 1)
                {
                _ff_scanRow(cy + 1, xL, xR, seedColor);
                }
            }

        pen = origPen;
        return !_gfx_ff_ovf;
        }

    // floodFill helper: scan one row in [xL..xR] for runs of
    // `seedColor`, push the leftmost x of each run as a new seed.
    void _ff_scanRow(u8 row, i16 xL, i16 xR, u8 seedColor)
        {
        i16 c = xL;
        bool inRun = false;
        while (c <= xR)
            {
            if (inline : getPixel(c, (i16)row) == seedColor)
                {
                if (!inRun)
                    {
                    if (_gfx_ff_count < 256)
                        {
                        _gfx_ff_xLo[_gfx_ff_head] = (u8)((u16)c & $FF);
                        _gfx_ff_xHi[_gfx_ff_head] = (u8)((u16)c >> 8);
                        _gfx_ff_ys[_gfx_ff_head] = row;
                        _gfx_ff_head = _gfx_ff_head + 1;
                        _gfx_ff_count = _gfx_ff_count + 1;
                        }
                    else
                        {
                        _gfx_ff_ovf = true;
                        }
                    inRun = true;
                    }
                }
            else
                {
                inRun = false;
                }
            c = c + 1;
            }
        return;
        }

    // Draw an 8x8 character glyph at pixel (x, y). Reads the glyph
    // from the OS character ROM via CHBAS ($02F4). ATASCII→internal
    // conversion follows the standard Atari mapping.
    void drawChar(i16 x, i16 y, u8 ch)
        {
        u8 c = ch & $7F;
        u8 internal;
        if (c < $20)
            {
            internal = c + $40;
            }
        else if (c < $60)
            {
            internal = c - $20;
            }
        else
            {
            internal = c;
            }

        u8 chbasPage;
        asm
            {
            LDA $02F4
            STA chbasPage
            }
        u16 glyphAddr =
            ((u16)chbasPage << 8) + ((u16)internal << 3);

        u8 row = 0;
        while (row < 8)
            {
            u8* rowPtr = (u8*)(glyphAddr + (u16)row);
            u8 b = *rowPtr;
            u8 rowByte = b;
            u8 bit = 0;
            while (bit < 8)
                {
                if ((rowByte & $80) != 0)
                    {
                    inline : plot(x + (i16)(u16)bit,
                                  y + (i16)(u16)row);
                    }
                rowByte = rowByte << 1;
                bit = bit + 1;
                }
            row = row + 1;
            }
        return;
        }

    // Draw an ASCII string starting at pixel (x, y), advancing
    // x by 8 per character. Newline ($0A) advances y by 8 and
    // resets x; null terminator ends the string.
    void drawText(i16 x, i16 y, string s)
        {
        i16 cx = x;
        i16 cy = y;
        u8 ch = *s;
        while (ch != 0)
            {
            if (ch == $0A)
                {
                cx = x;
                cy = cy + 8;
                }
            else
                {
                drawChar(cx, cy, ch);
                cx = cx + 8;
                }
            s = s + 1;
            ch = *s;
            }
        return;
        }

    // Set the OS graphics mode via CIO. Goes through IOCB 6 with
    // a CLOSE/OPEN cycle on "S:" — equivalent to BASIC's
    // `GRAPHICS N` (clear-screen variant). Updates SAVMSC and
    // DINDEX as a side effect. After return, a per-mode subclass
    // can be constructed and pointed at the new screen buffer
    // via `g.readFromOS()`.
    //
    // Note: setMode does NOT update this Gfx instance's sbase /
    // at / colours. Build the per-mode subclass and call its
    // readFromOS() afterwards.
    //
    // Shadow mode: CIOV ($E456) lives in OS ROM. Under
    // xl-shadow / xt-shadow-heap / similar, the ROM is paged out
    // by default, so a bare `JSR $E456` lands in uninitialised
    // RAM and crashes. The wrapper saves PORTB, sets bit 0
    // (re-enable ROM at $C000-$FFFF), runs the CIO sequence with
    // SEI to suppress IRQs (the shadow-IRQ trampoline assumes
    // ROM is OFF on entry — toggling PORTB mid-handler would
    // confuse it), then restores PORTB. On non-shadow targets
    // PORTB bit 0 is already 1 so the toggles are no-ops.
    static void setMode(u8 mode)
        {
        u8 m = mode;
        // Auto-restore-on-exit: signal that the screen mode is no
        // longer the OS-managed default. The runtime exit hook
        // (Gfx.atExit) reads this and re-issues setMode(GFX_GR0)
        // before the RTS to the loader, so programs that take
        // over the display via setupNative() / setupSplit() leave
        // the user back on a usable text screen instead of their
        // last drawn frame.
        _gfx_mode_changed = (u8)1;
        asm
        {
            SEI
            ; Disable VBI / DLI for the duration of the CIO open.
            ; The OS S: open loops for 7+ KB clearing screen RAM,
            ; long enough that several VBIs would fire. The xe
            ; shadow-VBI trampoline JMPs indirect through VVBLKI
            ; ($0222), and we've seen $0222 wind up as $0000 mid-
            ; open (likely because the OS reinitialises some
            ; shadow vectors during S: open before populating
            ; them again). Suppressing NMIs entirely until the
            ; open is done sidesteps the race; we re-arm $40
            ; (VBI only) at the end to restore normal VBI flow.
            LDA $D40E             ; save NMIEN
            PHA
            LDA #$00
            STA $D40E             ; disable all NMIs
            LDA PORTB             ; save PORTB (ROM bit 0)
            PHA
            ORA #$01              ; bit 0 = 1 -> ROM at $C000-$FFFF
            STA PORTB
            ; Lower RAMTOP ($6A) so the OS allocates the screen +
            ; display list BELOW our main code region. xe / xt put
            ; main code at $A000+; xl spans through $9FFF and
            ; doesn't leave room for an OS-managed GR.8 screen,
            ; so xl programs need a different setup (tracked
            ; separately). RAMTOP = page $A0 (= byte $A000)
            ; tells the OS that usable RAM ends at $A000; the
            ; OS picks screen at $9FFF - 8KB = $8000 for GR.8,
            ; with the display list just below. The OS also
            ; recomputes MEMTOP off RAMTOP automatically.
            LDA #$A0
            STA $6A               ; RAMTOP
            ; Pre-arm VVBLKI / VVBLKD ($0222/$0224) with the OS
            ; chain entries BEFORE the CIO sequence. The S:
            ; open's screen-clear loop takes long enough that a
            ; VBI fires mid-call; the xe shadow-VBI trampoline
            ; jumps through VVBLKI, and on this OS revision
            ; $0222 is observed as $0000 by then. Re-pinning
            ; here covers both the VBI-during-CIO case and the
            ; post-return case.
            LDA #<SYSVBV
            STA $0222
            LDA #>SYSVBV
            STA $0223
            LDA #<XITVBV
            STA $0224
            LDA #>XITVBV
            STA $0225
            ; CLOSE IOCB 6 (X = $60 = IOCB index * 16).
            LDX #$60
            LDA #$0C              ; CLOSE command
            STA ICCOM,X
            JSR CIOV
            ; OPEN "S:" with the requested mode. AUX1 = $1C
            ; ($0C R+W | $10 clear-screen). ICAX1 lives at $034A,
            ; ICAX2 at $034B; the symbolic names from atari.sym
            ; keep this honest.
            LDX #$60
            LDA #<_gfx_dev_S
            STA ICBAL,X
            LDA #>_gfx_dev_S
            STA ICBAH,X
            LDA m
            STA ICAX2,X
            LDA #$1C
            STA ICAX1,X
            LDA #$03              ; OPEN command
            STA ICCOM,X
            JSR CIOV
            ; Re-install VBI vectors via the OS-published SETVBV
            ; trampoline. Direct stores to $0222/$0223 race with
            ; VBI fetches; SETVBV serialises the install with
            ; interrupts disabled. A=6 = immediate vector
            ; (VVBLKI), Y/X = lo/hi of SYSVBV which is the OS
            ; chain entry. Then A=7 for VVBLKD = XITVBV.
            ; Without this the OS's S: open leaves $0222 zeroed
            ; on this OS revision and the next VBI dies in a
            ; JMP ($0222) -> $0000 -> BRK loop.
            LDY #<SYSVBV
            LDX #>SYSVBV
            LDA #$06              ; immediate VBI (= VVBLKI slot)
            JSR SETVBV
            LDY #<XITVBV
            LDX #>XITVBV
            LDA #$07              ; deferred VBI (= VVBLKD slot)
            JSR SETVBV
            ; The OS placed the GR.8 display list at ~$7Fxx
            ; (just below the screen at $8000-$9FFF). xtc heap
            ; on xe starts at heapTop = $7FFF and grows down,
            ; so the next new-expression would land on top of
            ; the OS-managed display list. Lower HP (xtc heap
            ; pointer; XTC_HP_LO/HI resolves the right ZP slot
            ; per target) to $7E00 so subsequent allocations
            ; clear the 256-byte DL. APPMHI (OS-tracked floor)
            ; gets the same value to keep CIO from growing into
            ; the heap.
            LDA #$00
            STA XTC_HP_LO
            LDA #$7E
            STA XTC_HP_HI
            LDA #$00
            STA $0E               ; APPMHI lo
            LDA #$7E
            STA $0F               ; APPMHI hi
            ; Restore PORTB and re-enable VBI.
            PLA
            STA PORTB
            PLA
            STA $D40E             ; restore NMIEN
            CLI
        }
        return;
        }

    // Restore the OS-managed text screen (GR.0) before program
    // exit. Programs that took over the display via
    // Gfx8.setupNative() or direct ANTIC pokes leave their
    // custom DL active when main returns, so the user lands on
    // whatever was last drawn — usually fine for tests, ugly
    // for anything visible. Calling Gfx.restoreGR0() right
    // before `return;` re-issues the CIO OPEN on "S:" with
    // mode 0, putting the OS back in charge of the screen.
    //
    // Cost: one full setMode(0) cycle (NMI suspend + CIO open
    // + VBI re-install + ROM toggle if shadow). Do not call
    // from interrupt context.
    static void restoreGR0(void)
        {
        Gfx.setMode(GFX_GR0);
        return;
        }

    // Runtime exit hook — called by the codegen-emitted post-
    // `_fn_main` shim before the RTS to the loader (i.e. on
    // every clean program exit, but not on `-Q loop` programs
    // which never reach the shim). Restores the OS-managed
    // text screen if-and-only-if the program changed the mode
    // at any point during execution.
    //
    // The codegen only emits the `JSR _cls_Gfx_atExit` if Gfx
    // is reachable in the program's call graph — programs that
    // never #import Gfx pay zero bytes for this feature. Even
    // when Gfx IS reachable, the cost at exit is one
    // `LDA / BEQ` (3 bytes inline at the call site) plus this
    // 4-byte body when the flag is unset; the full setMode(0)
    // path runs only when the program actually changed the
    // screen.
    static void atExit(void)
        {
        if (_gfx_mode_changed != (u8)0)
            {
            Gfx.setMode(GFX_GR0);
            }
        return;
        }
    }
