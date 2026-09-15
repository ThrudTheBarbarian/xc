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

// CharacterSet.xc — membership over byte values, as a 256-bit bitmap.
// =================================================================
//
// The thing M1 said xtc "lacks entirely" (private:docs/Design/m1-foundation-surface.md):
// NSCharacterSet, needed by rangeOfCharacterFromSet:,
// componentsSeparatedByCharactersInSet: and stringByTrimmingCharactersInSet:.
// A lexer is mostly character-class tests, so this is load-bearing for the
// self-hosting work rather than a convenience.
//
// Usage:
//   CharacterSet* ws = CharacterSet.whitespaceAndNewlines();
//   String* trimmed = line.trimmed(ws);
//   Array* fields = line.split(CharacterSet.withCString(",;"));
//
// The representation is a 32-byte bitmap held INLINE as an array ivar, not as a
// heap allocation:
//
//   * membership is one shift and one AND — no allocation, no pointer chase;
//   * there is no raw buffer to free, so no dealloc, and in particular none of
//     the "__arc_release on a raw buffer corrupts the xt6502 heap" hazard that
//     String and Data have to route around;
//   * and it makes the class WIDTH-NEUTRAL. Everything here is u8 or u16
//     arithmetic over 256 values, so unlike String / Array / Map / Set there is
//     no separate 6502 build of this file: it lives in generic/lib and is
//     shared by every target.
//
// Bytes, not characters. Above 127 this is a byte set, so it says nothing about
// multi-byte UTF-8 sequences — which is exactly what a tokeniser wants, and is
// the same assumption the rest of the library's ASCII handling already makes.

#import "Object.xc"

class CharacterSet
    {
    u8 _bits[32]; // one bit per byte value: bit (c & 7) of byte (c >> 3)

    void init(void)
        {
        for (u16 i = (u16)0; i < (u16)32; i = i + (u16)1)
            _bits[i] = (u8)0;
        }

    // ── Membership ───────────────────────────────────────────────
    bool contains(u8 c)
        {
        return (_bits[c >> (u8)3] & (u8)((u8)1 << (c & (u8)7))) != (u8)0;
        }

    void add(u8 c)
        {
        _bits[c >> (u8)3] = _bits[c >> (u8)3] | (u8)((u8)1 << (c & (u8)7));
        }

    void remove(u8 c)
        {
        _bits[c >> (u8)3] = _bits[c >> (u8)3] & (u8) ~((u8)1 << (c & (u8)7));
        }

    // Inclusive on both ends, and safe at the top of the range: the loop counts
    // in u16 so `addRange('a', 255)` cannot wrap round to zero forever.
    void addRange(u8 lo, u8 hi)
        {
        for (u16 c = (u16)lo; c <= (u16)hi; c = c + (u16)1)
            add((u8)c);
        }

    void addCString(u8* s)
        {
        if (s == (u8*)0)
            return;
        u16 i = (u16)0;
        while (s[i] != (u8)0)
            {
            add(s[i]);
            i = i + (u16)1;
            }
        }

    // Every byte NOT in the receiver. The receiver is untouched.
    CharacterSet* inverted(void)
        {
        CharacterSet* out = new CharacterSet();
        for (u16 i = (u16)0; i < (u16)32; i = i + (u16)1)
            out._bits[i] = (u8)~_bits[i];
        return out;
        }

    void formUnion(CharacterSet* other)
        {
        if (other == 0)
            return;
        for (u16 i = (u16)0; i < (u16)32; i = i + (u16)1)
            _bits[i] = _bits[i] | other._bits[i];
        }

    void formIntersection(CharacterSet* other)
        {
        if (other == 0)
            return;
        for (u16 i = (u16)0; i < (u16)32; i = i + (u16)1)
            _bits[i] = _bits[i] & other._bits[i];
        }

    bool isEmpty(void)
        {
        for (u16 i = (u16)0; i < (u16)32; i = i + (u16)1)
            if (_bits[i] != (u8)0)
                return false;
        return true;
        }

    // ── Builders ─────────────────────────────────────────────────
    // characterSetWithCharactersInString:. It takes a C string rather than a
    // String* so this file needs no import of String — String imports THIS one,
    // and two library files that import each other is a cycle. `String` grows
    // the convenience form (`s.asCharacterSet()`) on its own side.
    static CharacterSet* withCString(u8* s)
        {
        CharacterSet* cs = new CharacterSet();
        cs.addCString(s);
        return cs;
        }

    static CharacterSet* withRange(u8 lo, u8 hi)
        {
        CharacterSet* cs = new CharacterSet();
        cs.addRange(lo, hi);
        return cs;
        }

    // ── The standard sets ────────────────────────────────────────
    // Space and tab only — Foundation's whitespaceCharacterSet.
    static CharacterSet* whitespace(void)
        {
        CharacterSet* cs = new CharacterSet();
        cs.add((u8)32); // space
        cs.add((u8)9);  // tab
        return cs;
        }

    // CR, LF, and the two vertical movers. Foundation's newlineCharacterSet.
    static CharacterSet* newlines(void)
        {
        CharacterSet* cs = new CharacterSet();
        cs.add((u8)10); // LF
        cs.add((u8)13); // CR
        cs.add((u8)11); // VT
        cs.add((u8)12); // FF
        return cs;
        }

    // What `trimmed()` has always used, now nameable.
    static CharacterSet* whitespaceAndNewlines(void)
        {
        CharacterSet* cs = CharacterSet.whitespace();
        cs.formUnion(CharacterSet.newlines());
        return cs;
        }

    static CharacterSet* decimalDigits(void)
        {
        return CharacterSet.withRange((u8)'0', (u8)'9');
        }

    static CharacterSet* hexDigits(void)
        {
        CharacterSet* cs = CharacterSet.decimalDigits();
        cs.addRange((u8)'a', (u8)'f');
        cs.addRange((u8)'A', (u8)'F');
        return cs;
        }

    // ASCII letters. Deliberately not "everything a locale calls a letter" —
    // this is a byte set, and pretending otherwise would be the lie.
    static CharacterSet* letters(void)
        {
        CharacterSet* cs = new CharacterSet();
        cs.addRange((u8)'a', (u8)'z');
        cs.addRange((u8)'A', (u8)'Z');
        return cs;
        }

    static CharacterSet* alphanumerics(void)
        {
        CharacterSet* cs = CharacterSet.letters();
        cs.addRange((u8)'0', (u8)'9');
        return cs;
        }

    // The identifier set every tokeniser wants: letters, digits, underscore.
    static CharacterSet* identifiers(void)
        {
        CharacterSet* cs = CharacterSet.alphanumerics();
        cs.add((u8)'_');
        return cs;
        }
    }
