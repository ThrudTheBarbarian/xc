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

// Sha256.xc — SHA-256 (FIPS 180-4), the plain one-shot form.
//
//     Data* d = Sha256.of(bytes, n);          // 32 bytes
//     String* h = Sha256.hex(bytes, n);       // 64 hex characters
//
// What the par runtime's remote worker proves a pool secret with
// (ParRemote.xc), and what a WebSocket handshake or a content hash needs
// elsewhere. Pure xc, so it is the same on every hosted target.
#import "Foundation.xc"

u32 _sha256K[64] = {
    (u32)0x428a2f98, (u32)0x71374491, (u32)0xb5c0fbcf, (u32)0xe9b5dba5, (u32)0x3956c25b, (u32)0x59f111f1, (u32)0x923f82a4, (u32)0xab1c5ed5,
    (u32)0xd807aa98, (u32)0x12835b01, (u32)0x243185be, (u32)0x550c7dc3, (u32)0x72be5d74, (u32)0x80deb1fe, (u32)0x9bdc06a7, (u32)0xc19bf174,
    (u32)0xe49b69c1, (u32)0xefbe4786, (u32)0x0fc19dc6, (u32)0x240ca1cc, (u32)0x2de92c6f, (u32)0x4a7484aa, (u32)0x5cb0a9dc, (u32)0x76f988da,
    (u32)0x983e5152, (u32)0xa831c66d, (u32)0xb00327c8, (u32)0xbf597fc7, (u32)0xc6e00bf3, (u32)0xd5a79147, (u32)0x06ca6351, (u32)0x14292967,
    (u32)0x27b70a85, (u32)0x2e1b2138, (u32)0x4d2c6dfc, (u32)0x53380d13, (u32)0x650a7354, (u32)0x766a0abb, (u32)0x81c2c92e, (u32)0x92722c85,
    (u32)0xa2bfe8a1, (u32)0xa81a664b, (u32)0xc24b8b70, (u32)0xc76c51a3, (u32)0xd192e819, (u32)0xd6990624, (u32)0xf40e3585, (u32)0x106aa070,
    (u32)0x19a4c116, (u32)0x1e376c08, (u32)0x2748774c, (u32)0x34b0bcb5, (u32)0x391c0cb3, (u32)0x4ed8aa4a, (u32)0x5b9cca4f, (u32)0x682e6ff3,
    (u32)0x748f82ee, (u32)0x78a5636f, (u32)0x84c87814, (u32)0x8cc70208, (u32)0x90befffa, (u32)0xa4506ceb, (u32)0xbef9a3f7, (u32)0xc67178f2 };

class Sha256
    {
    static u32 _rotr(u32 x, u32 n)
        {
        return (x >> n) | (x << ((u32)32 - n));
        }

    // One 64-byte block into the state.
    static void _block(u32* h, u8* p)
        {
        u32 w[64];
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            w[i] = ((u32)p[i * (u32)4] << (u32)24) | ((u32)p[i * (u32)4 + (u32)1] << (u32)16)
                 | ((u32)p[i * (u32)4 + (u32)2] << (u32)8) | (u32)p[i * (u32)4 + (u32)3];
        for (u32 i = (u32)16; i < (u32)64; i = i + (u32)1)
            {
            u32 s0 = Sha256._rotr(w[i - (u32)15], (u32)7) ^ Sha256._rotr(w[i - (u32)15], (u32)18) ^ (w[i - (u32)15] >> (u32)3);
            u32 s1 = Sha256._rotr(w[i - (u32)2], (u32)17) ^ Sha256._rotr(w[i - (u32)2], (u32)19) ^ (w[i - (u32)2] >> (u32)10);
            w[i] = w[i - (u32)16] + s0 + w[i - (u32)7] + s1;
            }
        u32 a = h[0]; u32 b = h[1]; u32 c = h[2]; u32 d = h[3];
        u32 e = h[4]; u32 f = h[5]; u32 g = h[6]; u32 hh = h[7];
        for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1)
            {
            u32 S1 = Sha256._rotr(e, (u32)6) ^ Sha256._rotr(e, (u32)11) ^ Sha256._rotr(e, (u32)25);
            u32 ch = (e & f) ^ ((~e) & g);
            u32 t1 = hh + S1 + ch + _sha256K[i] + w[i];
            u32 S0 = Sha256._rotr(a, (u32)2) ^ Sha256._rotr(a, (u32)13) ^ Sha256._rotr(a, (u32)22);
            u32 maj = (a & b) ^ (a & c) ^ (b & c);
            u32 t2 = S0 + maj;
            hh = g; g = f; f = e; e = d + t1;
            d = c; c = b; b = a; a = t1 + t2;
            }
        h[0] = h[0] + a; h[1] = h[1] + b; h[2] = h[2] + c; h[3] = h[3] + d;
        h[4] = h[4] + e; h[5] = h[5] + f; h[6] = h[6] + g; h[7] = h[7] + hh;
        }

    // The digest of n bytes, as 32 bytes.
    static Data* of(u8* p, u32 n)
        {
        u32 h[8];
        h[0] = (u32)0x6a09e667; h[1] = (u32)0xbb67ae85; h[2] = (u32)0x3c6ef372; h[3] = (u32)0xa54ff53a;
        h[4] = (u32)0x510e527f; h[5] = (u32)0x9b05688c; h[6] = (u32)0x1f83d9ab; h[7] = (u32)0x5be0cd19;
        u32 at = (u32)0;
        while (n - at >= (u32)64)
            {
            Sha256._block(&h[0], p + at);
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
        Sha256._block(&h[0], &tail[0]);
        if (blocks == (u32)2)
            Sha256._block(&h[0], &tail[64]);
        Data* d = Data.withLength((u32)32);
        u8* o = d.bytes();
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            {
            o[i * (u32)4] = (u8)(h[i] >> (u32)24);
            o[i * (u32)4 + (u32)1] = (u8)(h[i] >> (u32)16);
            o[i * (u32)4 + (u32)2] = (u8)(h[i] >> (u32)8);
            o[i * (u32)4 + (u32)3] = (u8)h[i];
            }
        return d;
        }

    // The digest as 64 lower-case hex characters.
    static String* hex(u8* p, u32 n)
        {
        Data* d = Sha256.of(p, n);
        String* s = new String();
        u8* b = d.bytes();
        for (u32 i = (u32)0; i < (u32)32; i = i + (u32)1)
            {
            u32 hi = (u32)(b[i] >> (u8)4);
            u32 lo = (u32)(b[i] & (u8)15);
            s.appendByte(hi < (u32)10 ? (u8)((u32)'0' + hi) : (u8)((u32)'a' + hi - (u32)10));
            s.appendByte(lo < (u32)10 ? (u8)((u32)'0' + lo) : (u8)((u32)'a' + lo - (u32)10));
            }
        return s;
        }
    }
