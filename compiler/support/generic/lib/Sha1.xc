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
// Sha1.xc — SHA-1 (FIPS 180-4), as the WebSocket handshake needs it.
//
//     Data* d = Sha1.of(p, n);          // 20 bytes
//     String* s = Sha1.hex(p, n);       // 40 lower-case hex characters
//
// SHA-1 is not a secure hash and is here for protocols that fix it, not for
// anything new: use Sha256 for that.
#import "Foundation.xc"

class Sha1
    {
    static u32 _rotl(u32 x, u32 n)
        {
        return (x << n) | (x >> ((u32)32 - n));
        }

    // One 64-byte block into the state.
    static void _block(u32* h, u8* p)
        {
        u32 w[80];
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            w[i] = ((u32)p[i * (u32)4] << (u32)24) | ((u32)p[i * (u32)4 + (u32)1] << (u32)16)
                 | ((u32)p[i * (u32)4 + (u32)2] << (u32)8) | (u32)p[i * (u32)4 + (u32)3];
        for (u32 i = (u32)16; i < (u32)80; i = i + (u32)1)
            w[i] = Sha1._rotl(w[i - (u32)3] ^ w[i - (u32)8] ^ w[i - (u32)14] ^ w[i - (u32)16], (u32)1);
        u32 a = h[0];
        u32 b = h[1];
        u32 c = h[2];
        u32 d = h[3];
        u32 e = h[4];
        for (u32 i = (u32)0; i < (u32)80; i = i + (u32)1)
            {
            u32 f;
            u32 k;
            if (i < (u32)20)
                {
                f = (b & c) | ((~b) & d);
                k = (u32)0x5a827999;
                }
            else if (i < (u32)40)
                {
                f = b ^ c ^ d;
                k = (u32)0x6ed9eba1;
                }
            else if (i < (u32)60)
                {
                f = (b & c) | (b & d) | (c & d);
                k = (u32)0x8f1bbcdc;
                }
            else
                {
                f = b ^ c ^ d;
                k = (u32)0xca62c1d6;
                }
            u32 t = Sha1._rotl(a, (u32)5) + f + e + k + w[i];
            e = d;
            d = c;
            c = Sha1._rotl(b, (u32)30);
            b = a;
            a = t;
            }
        h[0] = h[0] + a;
        h[1] = h[1] + b;
        h[2] = h[2] + c;
        h[3] = h[3] + d;
        h[4] = h[4] + e;
        }

    // The digest of n bytes at p: 20 bytes of Data.
    static Data* of(u8* p, u32 n)
        {
        u32 h[5];
        h[0] = (u32)0x67452301; h[1] = (u32)0xefcdab89; h[2] = (u32)0x98badcfe; h[3] = (u32)0x10325476;
        h[4] = (u32)0xc3d2e1f0;
        u32 at = (u32)0;
        while (n - at >= (u32)64)
            {
            Sha1._block(&h[0], p + at);
            at = at + (u32)64;
            }
        // The tail: what is left, a 1 bit, zeros, and the bit length in 8
        // big-endian bytes — one block, or two when the tail is 56 or more.
        u8 tail[128];
        u32 rest = n - at;
        for (u32 i = (u32)0; i < (u32)128; i = i + (u32)1)
            tail[i] = (u8)0;
        for (u32 i = (u32)0; i < rest; i = i + (u32)1)
            tail[i] = p[at + i];
        tail[rest] = (u8)0x80;
        u32 blocks = rest >= (u32)56 ? (u32)2 : (u32)1;
        u64 bits = (u64)n * (u64)8;
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            tail[blocks * (u32)64 - (u32)1 - i] = (u8)(bits >> ((u64)i * (u64)8));
        Sha1._block(&h[0], &tail[0]);
        if (blocks == (u32)2)
            Sha1._block(&h[0], &tail[64]);
        Data* d = Data.withLength((u32)20);
        u8* o = d.bytes();
        for (u32 i = (u32)0; i < (u32)5; i = i + (u32)1)
            {
            o[i * (u32)4] = (u8)(h[i] >> (u32)24);
            o[i * (u32)4 + (u32)1] = (u8)(h[i] >> (u32)16);
            o[i * (u32)4 + (u32)2] = (u8)(h[i] >> (u32)8);
            o[i * (u32)4 + (u32)3] = (u8)h[i];
            }
        return d;
        }

    // The digest as 40 lower-case hex characters.
    static String* hex(u8* p, u32 n)
        {
        Data* d = Sha1.of(p, n);
        String* s = new String();
        u8* b = d.bytes();
        for (u32 i = (u32)0; i < (u32)20; i = i + (u32)1)
            {
            u32 hi = (u32)(b[i] >> (u8)4);
            u32 lo = (u32)(b[i] & (u8)15);
            s.appendByte(hi < (u32)10 ? (u8)((u32)'0' + hi) : (u8)((u32)'a' + hi - (u32)10));
            s.appendByte(lo < (u32)10 ? (u8)((u32)'0' + lo) : (u8)((u32)'a' + lo - (u32)10));
            }
        return s;
        }
    }
