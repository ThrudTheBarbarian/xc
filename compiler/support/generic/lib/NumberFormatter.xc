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
// NumberFormatter.xc — numbers to display text and back (NSNumberFormatter in
// shape).
// ===========================================================================
//
//     NumberFormatter* f = NumberFormatter.decimal();
//     f.format(Number.withI64((i64)1234567));            // "1,234,567"
//     NumberFormatter.currency(String.withCString("$"))
//         .format(Number.withDouble(1299.5d));           // "$1,299.50"
//     NumberFormatter.percent().format(Number.withDouble(0.25d));   // "25%"
//
// A formatter is a set of choices: a prefix and a suffix (a currency symbol,
// a unit), whether to group the integer digits and with what, the decimal
// separator, the least and most fraction digits, and a multiplier (100 for a
// percentage). Integers are formatted exactly. A double is rounded to the
// most fraction digits as C's printf rounds it (the nearest, ties to even on
// the binary value), then trailing zeros past the least are dropped. A minus
// sign goes before the prefix: "-$5.00".
//
// `parse` reads such text back, ignoring the grouping separator.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every target except xt6502.

#if ARCH_6502
#error "NumberFormatter: not available on xt6502"
#endif

#import "Foundation.xc"
#import "JSON.xc"

class NumberFormatter
    {
    String* prefix;
    String* suffix;
    bool grouping;           // separate thousands
    String* groupSeparator;  // ","
    String* decimalSeparator; // "."
    u8 minimumFractionDigits;
    u8 maximumFractionDigits;
    i64 multiplier;          // 1, or 100 for a percentage

    void init(void)
        {
        prefix = String.withCString("");
        suffix = String.withCString("");
        grouping = true;
        groupSeparator = String.withCString(",");
        decimalSeparator = String.withCString(".");
        minimumFractionDigits = (u8)0;
        maximumFractionDigits = (u8)3;
        multiplier = (i64)1;
        }

    // ── Ready-made styles ────────────────────────────────────────────────

    // Grouped, up to three fraction digits: 1,234.567.
    static NumberFormatter* decimal(void)
        {
        return new NumberFormatter();
        }

    // `symbol` in front and exactly two fraction digits: $1,299.00.
    static NumberFormatter* currency(String* symbol)
        {
        NumberFormatter* f = new NumberFormatter();
        f.prefix = symbol == 0 ? String.withCString("") : symbol;
        f.minimumFractionDigits = (u8)2;
        f.maximumFractionDigits = (u8)2;
        return f;
        }

    // Times 100, "%" after, no fraction digits: 0.256 is 26%.
    static NumberFormatter* percent(void)
        {
        NumberFormatter* f = new NumberFormatter();
        f.suffix = String.withCString("%");
        f.maximumFractionDigits = (u8)0;
        f.multiplier = (i64)100;
        return f;
        }

    // ── Formatting ───────────────────────────────────────────────────────

    // `n` as text; a null `n` is "".
    String* format(Number* n)
        {
        if (n == 0)
            return String.withCString("");
        if (n.isFloat())
            return formatDouble(n.asDouble());
        return formatI64(n.asI64());
        }

    String* formatI64(i64 v)
        {
        // Exact while the multiplied value fits; past that, in double.
        if (multiplier != (i64)1)
            {
            i64 lim = (i64)0x7FFFFFFFFFFFFFFF / multiplier;
            if (v > lim || v < (i64)0 - lim)
                return formatDouble((double)v);
            v = v * multiplier;
            }
        bool neg = v < (i64)0;
        u64 mag = neg ? (u64)0 - (u64)v : (u64)v;
        String* digits = String.withU64(mag);
        String* frac = String.withCString("");
        while (frac.byteLength() < (u32)minimumFractionDigits)
            frac.appendByte((u8)'0');
        return _assemble(neg, digits, frac);
        }

    String* formatDouble(double v)
        {
        if (v != v)
            return String.withCString("NaN");
        double x = v * (double)multiplier;
        if (x - x != 0.0d)
            {
            String* inf = String.withCString(x < 0.0d ? "-" : "");
            inf.append(prefix);
            inf.appendCString("∞");
            inf.append(suffix);
            return inf;
            }
        bool neg = x < 0.0d;
        if (neg)
            x = -x;
        String* fmt = String.withCString("%.");
        fmt.append(String.withU32((u32)maximumFractionDigits));
        fmt.appendCString("f");
        String* text = String.withCString("");
        text.appendFormat(fmt.cString(), x);
        u8* b = text.cString();
        u32 n = text.byteLength();
        u32 dot = n;
        for (u32 i = (u32)0; i < n; i++)
            {
            if (b[i] == (u8)'.')
                {
                dot = i;
                break;
                }
            }
        String* whole = text.substringBytes((u32)0, dot);
        u32 fracLen = dot < n ? n - dot - (u32)1 : (u32)0;
        // Trailing zeros past the least go.
        while (fracLen > (u32)minimumFractionDigits && b[dot + fracLen] == (u8)'0')
            fracLen = fracLen - (u32)1;
        String* frac = fracLen > (u32)0 ? text.substringBytes(dot + (u32)1, fracLen) : String.withCString("");
        while (frac.byteLength() < (u32)minimumFractionDigits)
            frac.appendByte((u8)'0');
        // A value that rounds to zero is not negative.
        bool allZero = true;
        for (u32 i = (u32)0; i < n; i++)
            {
            if (b[i] >= (u8)'1' && b[i] <= (u8)'9')
                allZero = false;
            }
        return _assemble(neg && !allZero, whole, frac);
        }

    // A fixed-point value: `scaled` in units of 10^-decimals, so 129900 with
    // 2 decimals is 1299.00. Exact on every target; the fraction is padded
    // or kept to `decimals` digits whatever the least and most are.
    String* formatFixed(i64 scaled, u8 decimals)
        {
        bool neg = scaled < (i64)0;
        u64 mag = neg ? (u64)0 - (u64)scaled : (u64)scaled;
        String* digits = String.withU64(mag);
        while (digits.byteLength() <= (u32)decimals)
            digits.insertCStringAtByte((u32)0, "0");
        u32 cut = digits.byteLength() - (u32)decimals;
        return _assemble(neg && mag != (u64)0, digits.substringBytes((u32)0, cut),
                         digits.substringFromByte(cut));
        }

    String* _assemble(bool neg, String* whole, String* frac)
        {
        String* out = String.withCString(neg ? "-" : "");
        out.append(prefix);
        u32 n = whole.byteLength();
        u8* w = whole.cString();
        for (u32 i = (u32)0; i < n; i++)
            {
            if (grouping && i > (u32)0 && (n - i) % (u32)3 == (u32)0)
                out.append(groupSeparator);
            out.appendByte(w[i]);
            }
        if (frac.byteLength() > (u32)0)
            {
            out.append(decimalSeparator);
            out.append(frac);
            }
        out.append(suffix);
        return out;
        }

    // ── Parsing ──────────────────────────────────────────────────────────

    // Whether `s` holds `w` at byte `i`.
    static bool _at(String* s, String* w, u32 i)
        {
        u32 n = w.byteLength();
        if (i + n > s.byteLength())
            return false;
        u8* a = s.cString();
        u8* b = w.cString();
        for (u32 k = (u32)0; k < n; k++)
            {
            if (a[i + k] != b[k])
                return false;
            }
        return true;
        }

    // The Number `text` shows, or null if it is not one: the prefix and
    // suffix are optional, a leading '-' may come before or after the prefix,
    // grouping separators are ignored, and the result is divided by the
    // multiplier. Text with no decimal separator gives an Int when it fits
    // and the multiplier divides it.
    Number* parse(String* text)
        {
        if (text == 0)
            return (Number*)0;
        String* t = text.trimmed();
        bool neg = false;
        if (t.hasPrefix(String.withCString("-")))
            {
            neg = true;
            t = t.substringFromByte((u32)1);
            }
        if (!prefix.isEmpty() && t.hasPrefix(prefix))
            t = t.substringFromByte(prefix.byteLength());
        if (!neg && t.hasPrefix(String.withCString("-")))
            {
            neg = true;
            t = t.substringFromByte((u32)1);
            }
        if (!suffix.isEmpty() && t.hasSuffix(suffix))
            t = t.substringBytes((u32)0, t.byteLength() - suffix.byteLength());
        t = t.trimmed();
        // Digits, with the decimal separator turned into '.'.
        String* plain = String.withCString("");
        bool isFloat = false;
        u32 i = (u32)0;
        u32 n = t.byteLength();
        u32 digits = (u32)0;
        while (i < n)
            {
            if (grouping && !groupSeparator.isEmpty() && NumberFormatter._at(t, groupSeparator, i))
                {
                i = i + groupSeparator.byteLength();
                continue;
                }
            if (!isFloat && !decimalSeparator.isEmpty() && NumberFormatter._at(t, decimalSeparator, i))
                {
                plain.appendByte((u8)'.');
                isFloat = true;
                i = i + decimalSeparator.byteLength();
                continue;
                }
            u8 c = t.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                return (Number*)0;
            plain.appendByte(c);
            digits++;
            i++;
            }
        if (digits == (u32)0)
            return (Number*)0;
        if (!isFloat && digits <= (u32)18)
            {
            i64 v = (i64)0;
            u8* p = plain.cString();
            for (u32 k = (u32)0; k < plain.byteLength(); k++)
                v = v * (i64)10 + (i64)(p[k] - (u8)'0');
            if (neg)
                v = (i64)0 - v;
            if (v % multiplier == (i64)0)
                return Number.withI64(v / multiplier);
            return Number.withDouble((double)v / (double)multiplier);
            }
        double d = _json_parseDouble(plain.cString(), plain.byteLength());
        if (neg)
            d = -d;
        return Number.withDouble(d / (double)multiplier);
        }
    }
