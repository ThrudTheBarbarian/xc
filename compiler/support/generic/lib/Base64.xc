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
// Base64.xc — the standard alphabet (RFC 4648), with `=` padding.
//
//     String* s = Base64.encode(p, n);
//     Data* d = Base64.decode(s);        // null when s is not base64
//
// decode skips nothing: a stray space or newline makes it fail, as it
// should for a protocol field. Strip them first for a wrapped body.
#import "Foundation.xc"

class Base64
    {
    // The character of a six-bit value.
    static u8 _char(u32 v)
        {
        if (v < (u32)26) return (u8)((u32)'A' + v);
        if (v < (u32)52) return (u8)((u32)'a' + v - (u32)26);
        if (v < (u32)62) return (u8)((u32)'0' + v - (u32)52);
        return v == (u32)62 ? (u8)'+' : (u8)'/';
        }

    static String* encode(u8* p, u32 n)
        {
        String* s = new String();
        u32 i = (u32)0;
        while (i + (u32)3 <= n)
            {
            u32 v = ((u32)p[i] << (u32)16) | ((u32)p[i + (u32)1] << (u32)8) | (u32)p[i + (u32)2];
            s.appendByte(Base64._char((v >> (u32)18) & (u32)63));
            s.appendByte(Base64._char((v >> (u32)12) & (u32)63));
            s.appendByte(Base64._char((v >> (u32)6) & (u32)63));
            s.appendByte(Base64._char(v & (u32)63));
            i = i + (u32)3;
            }
        if (n - i == (u32)1)
            {
            u32 v = (u32)p[i] << (u32)16;
            s.appendByte(Base64._char((v >> (u32)18) & (u32)63));
            s.appendByte(Base64._char((v >> (u32)12) & (u32)63));
            s.appendByte((u8)'=');
            s.appendByte((u8)'=');
            }
        else if (n - i == (u32)2)
            {
            u32 v = ((u32)p[i] << (u32)16) | ((u32)p[i + (u32)1] << (u32)8);
            s.appendByte(Base64._char((v >> (u32)18) & (u32)63));
            s.appendByte(Base64._char((v >> (u32)12) & (u32)63));
            s.appendByte(Base64._char((v >> (u32)6) & (u32)63));
            s.appendByte((u8)'=');
            }
        return s;
        }

    static String* encodeData(Data* d)
        {
        return Base64.encode(d.bytes(), d.length());
        }

    // The value of one character, or 64 for one outside the alphabet.
    static u32 _value(u8 c)
        {
        if (c >= (u8)'A' && c <= (u8)'Z') return (u32)(c - (u8)'A');
        if (c >= (u8)'a' && c <= (u8)'z') return (u32)(c - (u8)'a') + (u32)26;
        if (c >= (u8)'0' && c <= (u8)'9') return (u32)(c - (u8)'0') + (u32)52;
        if (c == (u8)'+') return (u32)62;
        if (c == (u8)'/') return (u32)63;
        return (u32)64;
        }

    static Data* decode(String* s)
        {
        u32 n = s.byteLength();
        if (n % (u32)4 != (u32)0)
            return (Data*)0;
        Data* d = new Data();
        u32 i = (u32)0;
        while (i < n)
            {
            u32 pad = (u32)0;
            u32 v = (u32)0;
            for (u32 k = (u32)0; k < (u32)4; k = k + (u32)1)
                {
                u8 c = s.byteAt(i + k);
                if (c == (u8)'=' && k >= (u32)2 && i + (u32)4 == n)
                    {
                    pad = pad + (u32)1;
                    v = v << (u32)6;
                    continue;
                    }
                u32 x = Base64._value(c);
                if (x == (u32)64 || pad != (u32)0)
                    return (Data*)0;
                v = (v << (u32)6) | x;
                }
            d.appendByte((u8)(v >> (u32)16));
            if (pad < (u32)2)
                d.appendByte((u8)(v >> (u32)8));
            if (pad < (u32)1)
                d.appendByte((u8)v);
            i = i + (u32)4;
            }
        return d;
        }
    }
