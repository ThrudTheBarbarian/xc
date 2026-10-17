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

// Sha512.xc — SHA-512 (FIPS 180-4), the plain one-shot form.
//
//     Data* d = Sha512.of(bytes, n);          // 64 bytes
//
// What Ed25519 (Ed25519.xc) hashes with. Pure xc, the same on every hosted
// target.
#import "Foundation.xc"

u64 _sha512K[80] = {
    (u64)0x428a2f98d728ae22, (u64)0x7137449123ef65cd, (u64)0xb5c0fbcfec4d3b2f, (u64)0xe9b5dba58189dbbc,
    (u64)0x3956c25bf348b538, (u64)0x59f111f1b605d019, (u64)0x923f82a4af194f9b, (u64)0xab1c5ed5da6d8118,
    (u64)0xd807aa98a3030242, (u64)0x12835b0145706fbe, (u64)0x243185be4ee4b28c, (u64)0x550c7dc3d5ffb4e2,
    (u64)0x72be5d74f27b896f, (u64)0x80deb1fe3b1696b1, (u64)0x9bdc06a725c71235, (u64)0xc19bf174cf692694,
    (u64)0xe49b69c19ef14ad2, (u64)0xefbe4786384f25e3, (u64)0x0fc19dc68b8cd5b5, (u64)0x240ca1cc77ac9c65,
    (u64)0x2de92c6f592b0275, (u64)0x4a7484aa6ea6e483, (u64)0x5cb0a9dcbd41fbd4, (u64)0x76f988da831153b5,
    (u64)0x983e5152ee66dfab, (u64)0xa831c66d2db43210, (u64)0xb00327c898fb213f, (u64)0xbf597fc7beef0ee4,
    (u64)0xc6e00bf33da88fc2, (u64)0xd5a79147930aa725, (u64)0x06ca6351e003826f, (u64)0x142929670a0e6e70,
    (u64)0x27b70a8546d22ffc, (u64)0x2e1b21385c26c926, (u64)0x4d2c6dfc5ac42aed, (u64)0x53380d139d95b3df,
    (u64)0x650a73548baf63de, (u64)0x766a0abb3c77b2a8, (u64)0x81c2c92e47edaee6, (u64)0x92722c851482353b,
    (u64)0xa2bfe8a14cf10364, (u64)0xa81a664bbc423001, (u64)0xc24b8b70d0f89791, (u64)0xc76c51a30654be30,
    (u64)0xd192e819d6ef5218, (u64)0xd69906245565a910, (u64)0xf40e35855771202a, (u64)0x106aa07032bbd1b8,
    (u64)0x19a4c116b8d2d0c8, (u64)0x1e376c085141ab53, (u64)0x2748774cdf8eeb99, (u64)0x34b0bcb5e19b48a8,
    (u64)0x391c0cb3c5c95a63, (u64)0x4ed8aa4ae3418acb, (u64)0x5b9cca4f7763e373, (u64)0x682e6ff3d6b2b8a3,
    (u64)0x748f82ee5defb2fc, (u64)0x78a5636f43172f60, (u64)0x84c87814a1f0ab72, (u64)0x8cc702081a6439ec,
    (u64)0x90befffa23631e28, (u64)0xa4506cebde82bde9, (u64)0xbef9a3f7b2c67915, (u64)0xc67178f2e372532b,
    (u64)0xca273eceea26619c, (u64)0xd186b8c721c0c207, (u64)0xeada7dd6cde0eb1e, (u64)0xf57d4f7fee6ed178,
    (u64)0x06f067aa72176fba, (u64)0x0a637dc5a2c898a6, (u64)0x113f9804bef90dae, (u64)0x1b710b35131c471b,
    (u64)0x28db77f523047d84, (u64)0x32caab7b40c72493, (u64)0x3c9ebe0a15c9bebc, (u64)0x431d67c49c100d4c,
    (u64)0x4cc5d4becb3e42b6, (u64)0x597f299cfc657e2a, (u64)0x5fcb6fab3ad6faec, (u64)0x6c44198c4a475817 };

class Sha512
    {
    static u64 _rotr(u64 x, u64 n)
        {
        return (x >> n) | (x << ((u64)64 - n));
        }

    // One 128-byte block into the state.
    static void _block(u64* h, u8* p)
        {
        u64 w[80];
        for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
            {
            u64 v = (u64)0;
            for (u32 k = (u32)0; k < (u32)8; k = k + (u32)1)
                v = (v << (u64)8) | (u64)p[i * (u32)8 + k];
            w[i] = v;
            }
        for (u32 i = (u32)16; i < (u32)80; i = i + (u32)1)
            {
            u64 a = w[i - (u32)15];
            u64 b = w[i - (u32)2];
            u64 s0 = Sha512._rotr(a, (u64)1) ^ Sha512._rotr(a, (u64)8) ^ (a >> (u64)7);
            u64 s1 = Sha512._rotr(b, (u64)19) ^ Sha512._rotr(b, (u64)61) ^ (b >> (u64)6);
            w[i] = w[i - (u32)16] + s0 + w[i - (u32)7] + s1;
            }
        u64 a = h[0];
        u64 b = h[1];
        u64 c = h[2];
        u64 d = h[3];
        u64 e = h[4];
        u64 f = h[5];
        u64 g = h[6];
        u64 hh = h[7];
        for (u32 i = (u32)0; i < (u32)80; i = i + (u32)1)
            {
            u64 s1 = Sha512._rotr(e, (u64)14) ^ Sha512._rotr(e, (u64)18) ^ Sha512._rotr(e, (u64)41);
            u64 ch = (e & f) ^ (~e & g);
            u64 t1 = hh + s1 + ch + _sha512K[i] + w[i];
            u64 s0 = Sha512._rotr(a, (u64)28) ^ Sha512._rotr(a, (u64)34) ^ Sha512._rotr(a, (u64)39);
            u64 mj = (a & b) ^ (a & c) ^ (b & c);
            u64 t2 = s0 + mj;
            hh = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = b;
            b = a;
            a = t1 + t2;
            }
        h[0] = h[0] + a;
        h[1] = h[1] + b;
        h[2] = h[2] + c;
        h[3] = h[3] + d;
        h[4] = h[4] + e;
        h[5] = h[5] + f;
        h[6] = h[6] + g;
        h[7] = h[7] + hh;
        }

    // The digest of n bytes into out (64 bytes).
    static void into(u8* out, u8* p, u32 n)
        {
        u64 h[8];
        h[0] = (u64)0x6a09e667f3bcc908;
        h[1] = (u64)0xbb67ae8584caa73b;
        h[2] = (u64)0x3c6ef372fe94f82b;
        h[3] = (u64)0xa54ff53a5f1d36f1;
        h[4] = (u64)0x510e527fade682d1;
        h[5] = (u64)0x9b05688c2b3e6c1f;
        h[6] = (u64)0x1f83d9abfb41bd6b;
        h[7] = (u64)0x5be0cd19137e2179;
        u32 at = (u32)0;
        while (n - at >= (u32)128)
            {
            Sha512._block(&h[0], p + at);
            at = at + (u32)128;
            }
        // The tail: what is left, a 1 bit, zeros, and the bit length in 16
        // big-endian bytes — one block, or two when the tail is 112 or more.
        u8 tail[256];
        u32 rest = n - at;
        for (u32 i = (u32)0; i < (u32)256; i = i + (u32)1)
            tail[i] = (u8)0;
        for (u32 i = (u32)0; i < rest; i = i + (u32)1)
            tail[i] = p[at + i];
        tail[rest] = (u8)0x80;
        u32 blocks = rest >= (u32)112 ? (u32)2 : (u32)1;
        u64 bits = (u64)n * (u64)8;
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            tail[blocks * (u32)128 - (u32)1 - i] = (u8)(bits >> ((u64)i * (u64)8));
        Sha512._block(&h[0], &tail[0]);
        if (blocks == (u32)2)
            Sha512._block(&h[0], &tail[128]);
        for (u32 i = (u32)0; i < (u32)8; i = i + (u32)1)
            for (u32 k = (u32)0; k < (u32)8; k = k + (u32)1)
                out[i * (u32)8 + k] = (u8)(h[i] >> ((u64)56 - (u64)k * (u64)8));
        }

    // The digest of n bytes, as 64 bytes.
    static Data* of(u8* p, u32 n)
        {
        Data* d = Data.withLength((u32)64);
        Sha512.into(d.bytes(), p, n);
        return d;
        }
    }
