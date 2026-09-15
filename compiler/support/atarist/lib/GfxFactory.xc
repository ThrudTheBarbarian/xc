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

// GfxFactory.xc (arm64) — comprehensive Gfx<N> port.
// =================================================================
//
// All four Atari Gfx modes (GR.6 / 7 / 8 / 15) ported to plain xtc
// for arm64. The xt6502 versions in support/6502/lib/ rely on
// inline 6502 asm for the per-pixel hot loops; this version drops
// all asm and uses portable subscripts / shifts / masks. The bit
// layouts match xt6502 byte-for-byte so the same fixture assertions
// pass on both backends.
//
// The framebuffer is held as `u8* buf` (not as a u16 sbase like the
// xt6502 ivars — arm64 pointers are 8 bytes and the truncation the
// asm version uses to fit ZP would lose the high bytes).
//
// Virtual dispatch caveat: the Gfx base class's higher-level
// drawing methods (rect / circle / arc / oval / line / etc.) call
// the per-mode `plot` / `hline` / `vline` primitives via `inline:`
// so the bare self-call resolves through the receiver's vtable to
// the subclass's override at runtime, not statically to the base-
// class stub (see Task #190).

#import "Stdio.xc"

// Atari graphics-mode constants used by the gfxCreate() factory.
// Values match the BASIC GRAPHICS N numbering and the constants in
// support/6502/lib/Gfx.xc so the same fixtures compile on both
// backends.
#define GFX_GR6 6
#define GFX_GR7 7
#define GFX_GR8 8
#define GFX_GR15 15

#define GFX_160_96_1 GFX_GR6
#define GFX_160_96_2 GFX_GR7
#define GFX_320_192_1 GFX_GR8
#define GFX_160_192_2 GFX_GR15

struct Point
    {
    i16 x;
    i16 y;
    }

    // 256-entry sin LUT used by oval(). Same values as the xt6502 copy.
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

// floodFill seed-queue ring buffer. Lazily heap-allocated on the
// first floodFill call so programs that never flood-fill don't pay.
u8* _gfx_ff_xLo;
u8* _gfx_ff_xHi;
u8* _gfx_ff_ys;
u8 _gfx_ff_head;
u8 _gfx_ff_tail;
u16 _gfx_ff_count;
bool _gfx_ff_ovf;

// ─────────────────────────────────────────────────────────────────
// Gfx — abstract base class.
// ─────────────────────────────────────────────────────────────────

class Gfx
    {
    u8* buf;  // framebuffer wired by the subclass init()
    Point at; // current pen position
    u8 pen;   // bit polarity for stroke draws
    u8 fillColor;
    u16 clearBytes; // bytes the clear() loop walks
    u16 _width;     // pixels
    u16 _height;    // pixels

    void init(void)
        {
        buf = (u8*)0;
        at.x = (i16)0;
        at.y = (i16)0;
        pen = (u8)1;
        fillColor = (u8)0;
        clearBytes = (u16)0;
        _width = (u16)0;
        _height = (u16)0;
        return;
        }

    // Per-mode primitives — subclasses override.
    void plot(i16 x, i16 y)
        {
        return;
        }
    u8 getPixel(i16 x, i16 y)
        {
        return (u8)0;
        }
    void hline(i16 x0, i16 x1, i16 y)
        {
        return;
        }
    void vline(i16 x, i16 y0, i16 y1)
        {
        return;
        }

    // Fill the framebuffer with $00 (fillColor 0) or $FF (non-zero).
    void clear(void)
        {
        u8 fill = (u8)0;
        if (fillColor != (u8)0)
            {
            fill = (u8)$FF;
            }
        u16 i = (u16)0;
        while (i < clearBytes)
            {
            buf[i] = fill;
            i = i + (u16)1;
            }
        return;
        }

    // State.
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

    // Rectangle outline.
    void rect(i16 x0, i16 y0, i16 x1, i16 y1)
        {
        inline : hline(x0, x1, y0);
        inline : hline(x0, x1, y1);
        inline : vline(x0, y0, y1);
        inline : vline(x1, y0, y1);
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

    // Arc outline — gated by quadrant mask. Bits select quadrants in
    // the same order as the xt6502 version: $01 top-right, $02 top-
    // left, $04 bottom-left, $08 bottom-right.
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

    // Filled pie — same shape as fillArc for the quadrant-mask form.
    void fillPie(i16 cx, i16 cy, i16 r, u8 quadrants)
        {
        fillArc(cx, cy, r, quadrants);
        return;
        }

    // Pie outline — arc plus radial edges where the arc opens
    // along an axis.
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

    // Outline ellipse — parametric with the 256-entry sin LUT.
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
        i16 t;
        i16 cosVal;
        i16 sinVal;
        i16 xOff;
        i16 yOff;
        i16 px;
        i16 py;
        i16 prevX = 0;
        i16 prevY = 0;
        for (t = 0; t < 256; t++)
            {
            cosVal = (i16)_gfx_sinTable[(t + 64) & $FF] - 128;
            sinVal = (i16)_gfx_sinTable[t] - 128;
            if (cosVal >= 0)
                {
                xOff = (rx * cosVal + 64) / 128;
                }
            else
                {
                xOff = (rx * cosVal - 64) / 128;
                }
            if (sinVal >= 0)
                {
                yOff = (ry * sinVal + 64) / 128;
                }
            else
                {
                yOff = (ry * sinVal - 64) / 128;
                }
            px = cx + xOff;
            py = cy + yOff;
            if (t > 0)
                {
                i16 adx = px - prevX;
                i16 ady = py - prevY;
                if (adx < 0)
                    {
                    adx = -adx;
                    }
                if (ady < 0)
                    {
                    ady = -ady;
                    }
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
        i16 y;
        i16 hw;
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

    // Line using Bresenham. Axis-aligned cases route to hline / vline.
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

    // Flood fill — scanline. Uses _gfx_ff_* globals for the seed
    // queue (heap-allocated lazily on first call).
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
            _gfx_ff_xLo = new u8[(u16)256];
            _gfx_ff_xHi = new u8[(u16)256];
            _gfx_ff_ys = new u8[(u16)256];
            }
        _gfx_ff_head = (u8)0;
        _gfx_ff_tail = (u8)0;
        _gfx_ff_count = (u16)0;
        _gfx_ff_ovf = false;
        _gfx_ff_xLo[(u16)0] = (u8)((u16)sx & $FF);
        _gfx_ff_xHi[(u16)0] = (u8)((u16)sx >> 8);
        _gfx_ff_ys[(u16)0] = (u8)sy;
        _gfx_ff_head = (u8)1;
        _gfx_ff_count = (u16)1;
        u8 origPen = pen;
        pen = newColor;
        while (_gfx_ff_count > (u16)0)
            {
            u16 cx = (u16)_gfx_ff_xLo[(u16)_gfx_ff_tail] | ((u16)_gfx_ff_xHi[(u16)_gfx_ff_tail] << 8);
            u8 cy = _gfx_ff_ys[(u16)_gfx_ff_tail];
            _gfx_ff_tail = _gfx_ff_tail + (u8)1;
            _gfx_ff_count = _gfx_ff_count - (u16)1;
            if (inline : getPixel((i16)cx, (i16)cy) != seedColor)
                {
                continue;
                }
            i16 xL = (i16)cx;
            while (xL > 0 && inline : getPixel(xL - 1, (i16)cy) == seedColor)
                {
                xL = xL - 1;
                }
            i16 xR = (i16)cx;
            while (xR < (i16)(_width - 1) && inline : getPixel(xR + 1, (i16)cy) == seedColor)
                {
                xR = xR + 1;
                }
            inline : hline(xL, xR, (i16)cy);
            if (cy > (u8)0)
                {
                _ff_scanRow(cy - (u8)1, xL, xR, seedColor);
                }
            if ((u16)cy < _height - (u16)1)
                {
                _ff_scanRow(cy + (u8)1, xL, xR, seedColor);
                }
            }
        pen = origPen;
        return !_gfx_ff_ovf;
        }

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
                    if (_gfx_ff_count < (u16)256)
                        {
                        _gfx_ff_xLo[(u16)_gfx_ff_head] = (u8)((u16)c & $FF);
                        _gfx_ff_xHi[(u16)_gfx_ff_head] = (u8)((u16)c >> 8);
                        _gfx_ff_ys[(u16)_gfx_ff_head] = row;
                        _gfx_ff_head = _gfx_ff_head + (u8)1;
                        _gfx_ff_count = _gfx_ff_count + (u16)1;
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

    }

    // ─────────────────────────────────────────────────────────────────
    // Gfx8 — 320 × 192 × 1bpp (7680 bytes).
    //   Byte offset = y * 40 + (x >> 3); bit = 7 - (x & 7).
    //   Pen 0 clears the bit, non-zero sets it.
    // ─────────────────────────────────────────────────────────────────

    class Gfx8 : Gfx
    {
    void init(u8* b)
        {
        buf = b;
        at.x = (i16)0;
        at.y = (i16)0;
        pen = (u8)1;
        fillColor = (u8)0;
        clearBytes = (u16)7680;
        _width = (u16)320;
        _height = (u16)192;
        return;
        }

    void plot(i16 x, i16 y)
        {
        if (x < 0 || x >= 320 || y < 0 || y >= 192)
            {
            return;
            }
        u16 off = (u16)y * (u16)40 + ((u16)x >> 3);
        u8 mask = (u8)1 << ((u8)7 - (u8)((u16)x & $07));
        if (pen != (u8)0)
            {
            buf[off] = buf[off] | mask;
            }
        else
            {
            buf[off] = buf[off] & (u8)(~mask);
            }
        return;
        }

    u8 getPixel(i16 x, i16 y)
        {
        if (x < 0 || x >= 320 || y < 0 || y >= 192)
            {
            return (u8)0;
            }
        u16 off = (u16)y * (u16)40 + ((u16)x >> 3);
        u8 mask = (u8)1 << ((u8)7 - (u8)((u16)x & $07));
        if ((buf[off] & mask) != (u8)0)
            {
            return (u8)1;
            }
        return (u8)0;
        }

    void hline(i16 x0, i16 x1, i16 y)
        {
        if (y < 0 || y >= 192)
            {
            return;
            }
        i16 lo = (x0 < x1) ? x0 : x1;
        i16 hi = (x0 < x1) ? x1 : x0;
        if (hi < 0 || lo >= 320)
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
        i16 xi = lo;
        while (xi <= hi)
            {
            inline : plot(xi, y);
            xi = xi + 1;
            }
        return;
        }

    void vline(i16 x, i16 y0, i16 y1)
        {
        if (x < 0 || x >= 320)
            {
            return;
            }
        i16 lo = (y0 < y1) ? y0 : y1;
        i16 hi = (y0 < y1) ? y1 : y0;
        if (hi < 0 || lo >= 192)
            {
            return;
            }
        if (lo < 0)
            {
            lo = 0;
            }
        if (hi >= 192)
            {
            hi = 191;
            }
        i16 yi = lo;
        while (yi <= hi)
            {
            inline : plot(x, yi);
            yi = yi + 1;
            }
        return;
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Gfx6 — 160 × 96 × 1bpp (1920 bytes). Same packing as Gfx8 but
    // half the horizontal resolution / 20 bytes per row, and HALF the
    // vertical resolution (Atari GR.6 is 96 lines, not 192).
    // ─────────────────────────────────────────────────────────────────

    class Gfx6 : Gfx
    {
    void init(u8* b)
        {
        buf = b;
        at.x = (i16)0;
        at.y = (i16)0;
        pen = (u8)1;
        fillColor = (u8)0;
        clearBytes = (u16)1920;
        _width = (u16)160;
        _height = (u16)96;
        return;
        }

    void plot(i16 x, i16 y)
        {
        if (x < 0 || x >= 160 || y < 0 || y >= 96)
            {
            return;
            }
        u16 off = (u16)y * (u16)20 + ((u16)x >> 3);
        u8 mask = (u8)1 << ((u8)7 - (u8)((u16)x & $07));
        if (pen != (u8)0)
            {
            buf[off] = buf[off] | mask;
            }
        else
            {
            buf[off] = buf[off] & (u8)(~mask);
            }
        return;
        }

    u8 getPixel(i16 x, i16 y)
        {
        if (x < 0 || x >= 160 || y < 0 || y >= 96)
            {
            return (u8)0;
            }
        u16 off = (u16)y * (u16)20 + ((u16)x >> 3);
        u8 mask = (u8)1 << ((u8)7 - (u8)((u16)x & $07));
        if ((buf[off] & mask) != (u8)0)
            {
            return (u8)1;
            }
        return (u8)0;
        }

    void hline(i16 x0, i16 x1, i16 y)
        {
        if (y < 0 || y >= 96)
            {
            return;
            }
        i16 lo = (x0 < x1) ? x0 : x1;
        i16 hi = (x0 < x1) ? x1 : x0;
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
        i16 xi = lo;
        while (xi <= hi)
            {
            inline : plot(xi, y);
            xi = xi + 1;
            }
        return;
        }

    void vline(i16 x, i16 y0, i16 y1)
        {
        if (x < 0 || x >= 160)
            {
            return;
            }
        i16 lo = (y0 < y1) ? y0 : y1;
        i16 hi = (y0 < y1) ? y1 : y0;
        if (hi < 0 || lo >= 96)
            {
            return;
            }
        if (lo < 0)
            {
            lo = 0;
            }
        if (hi >= 96)
            {
            hi = 95;
            }
        i16 yi = lo;
        while (yi <= hi)
            {
            inline : plot(x, yi);
            yi = yi + 1;
            }
        return;
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Gfx7 — 160 × 96 × 2bpp (3840 bytes). 4 pixels per byte, two bits
    // each. Byte offset = y * 40 + (x >> 2); shift = 6 - 2*(x & 3) so
    // pixel 0 is in the top two bits.
    // ─────────────────────────────────────────────────────────────────

    class Gfx7 : Gfx
    {
    void init(u8* b)
        {
        buf = b;
        at.x = (i16)0;
        at.y = (i16)0;
        pen = (u8)1;
        fillColor = (u8)0;
        clearBytes = (u16)3840;
        _width = (u16)160;
        _height = (u16)96;
        return;
        }

    void plot(i16 x, i16 y)
        {
        if (x < 0 || x >= 160 || y < 0 || y >= 96)
            {
            return;
            }
        u16 off = (u16)y * (u16)40 + ((u16)x >> 2);
        u8 shift = (u8)6 - (u8)(((u16)x & $03) << 1);
        u8 clrMsk = (u8)($03 << shift);
        u8 val = (u8)((pen & $03) << shift);
        buf[off] = (buf[off] & (u8)(~clrMsk)) | val;
        return;
        }

    u8 getPixel(i16 x, i16 y)
        {
        if (x < 0 || x >= 160 || y < 0 || y >= 96)
            {
            return (u8)0;
            }
        u16 off = (u16)y * (u16)40 + ((u16)x >> 2);
        u8 shift = (u8)6 - (u8)(((u16)x & $03) << 1);
        return (buf[off] >> shift) & $03;
        }

    void hline(i16 x0, i16 x1, i16 y)
        {
        if (y < 0 || y >= 96)
            {
            return;
            }
        i16 lo = (x0 < x1) ? x0 : x1;
        i16 hi = (x0 < x1) ? x1 : x0;
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
        i16 xi = lo;
        while (xi <= hi)
            {
            inline : plot(xi, y);
            xi = xi + 1;
            }
        return;
        }

    void vline(i16 x, i16 y0, i16 y1)
        {
        if (x < 0 || x >= 160)
            {
            return;
            }
        i16 lo = (y0 < y1) ? y0 : y1;
        i16 hi = (y0 < y1) ? y1 : y0;
        if (hi < 0 || lo >= 96)
            {
            return;
            }
        if (lo < 0)
            {
            lo = 0;
            }
        if (hi >= 96)
            {
            hi = 95;
            }
        i16 yi = lo;
        while (yi <= hi)
            {
            inline : plot(x, yi);
            yi = yi + 1;
            }
        return;
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Gfx15 — 160 × 192 × 2bpp (7680 bytes). Same packing as Gfx7 but
    // taller. 4 pixels per byte.
    // ─────────────────────────────────────────────────────────────────

    class Gfx15 : Gfx
    {
    void init(u8* b)
        {
        buf = b;
        at.x = (i16)0;
        at.y = (i16)0;
        pen = (u8)1;
        fillColor = (u8)0;
        clearBytes = (u16)7680;
        _width = (u16)160;
        _height = (u16)192;
        return;
        }

    void plot(i16 x, i16 y)
        {
        if (x < 0 || x >= 160 || y < 0 || y >= 192)
            {
            return;
            }
        u16 off = (u16)y * (u16)40 + ((u16)x >> 2);
        u8 shift = (u8)6 - (u8)(((u16)x & $03) << 1);
        u8 clrMsk = (u8)($03 << shift);
        u8 val = (u8)((pen & $03) << shift);
        buf[off] = (buf[off] & (u8)(~clrMsk)) | val;
        return;
        }

    u8 getPixel(i16 x, i16 y)
        {
        if (x < 0 || x >= 160 || y < 0 || y >= 192)
            {
            return (u8)0;
            }
        u16 off = (u16)y * (u16)40 + ((u16)x >> 2);
        u8 shift = (u8)6 - (u8)(((u16)x & $03) << 1);
        return (buf[off] >> shift) & $03;
        }

    void hline(i16 x0, i16 x1, i16 y)
        {
        if (y < 0 || y >= 192)
            {
            return;
            }
        i16 lo = (x0 < x1) ? x0 : x1;
        i16 hi = (x0 < x1) ? x1 : x0;
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
        i16 xi = lo;
        while (xi <= hi)
            {
            inline : plot(xi, y);
            xi = xi + 1;
            }
        return;
        }

    void vline(i16 x, i16 y0, i16 y1)
        {
        if (x < 0 || x >= 160)
            {
            return;
            }
        i16 lo = (y0 < y1) ? y0 : y1;
        i16 hi = (y0 < y1) ? y1 : y0;
        if (hi < 0 || lo >= 192)
            {
            return;
            }
        if (lo < 0)
            {
            lo = 0;
            }
        if (hi >= 192)
            {
            hi = 191;
            }
        i16 yi = lo;
        while (yi <= hi)
            {
            inline : plot(x, yi);
            yi = yi + 1;
            }
        return;
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // gfxCreate(mode, textRows) — factory for the Gfx<N> subclasses.
    //
    // On arm64 there's no real display, so every mode allocates an
    // off-screen heap buffer sized to the mode's pixel layout and
    // returns a freshly-constructed subclass instance. `textRows` is
    // accepted for API parity with the Atari version but ignored
    // (no ANTIC dlist to build).
    // ─────────────────────────────────────────────────────────────────
    Gfx* gfxCreate(u8 mode, u8 textRows)
    {
    if (mode == GFX_320_192_1)
        {
        u8* buf = new u8[7680];
        Gfx8* g = new Gfx8(buf);
        return (Gfx*)g;
        }
    if (mode == GFX_160_96_1)
        {
        u8* buf = new u8[1920];
        Gfx6* g = new Gfx6(buf);
        return (Gfx*)g;
        }
    if (mode == GFX_160_96_2)
        {
        u8* buf = new u8[3840];
        Gfx7* g = new Gfx7(buf);
        return (Gfx*)g;
        }
    if (mode == GFX_160_192_2)
        {
        u8* buf = new u8[7680];
        Gfx15* g = new Gfx15(buf);
        return (Gfx*)g;
        }
    return (Gfx*)0;
    }
