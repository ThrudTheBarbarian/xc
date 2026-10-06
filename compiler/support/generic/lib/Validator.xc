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
// Validator.xc — rules a field's text must pass, with a message for each.
// ===========================================================================
//
//     Validator* v = new Validator();
//     v.requireNonEmpty(String.withCString("Enter a name."));
//     v.requireMaxLength((u32)40, String.withCString("At most 40 characters."));
//     v.requireMatch(String.withCString("[A-Za-z' -]+"), String.withCString("Letters only."));
//     v.firstError(String.withCString(""));        // "Enter a name."
//     v.validate(String.withCString("Ada"));        // true
//
// A validator is a list of rules, each with the message to show when it
// fails: the check behind a text field's live validation and a form's
// Submit button. Rules are checked in the order they were added.
//
// Lengths count characters (UTF-8 sequences), not bytes. A pattern must match
// the whole text. The integer and number rules read the text as JSON writes
// a number, after trimming white space.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every target except xt6502.

#if ARCH_6502
#error "Validator: not available on xt6502"
#endif

#import "Foundation.xc"
#import "JSON.xc"
#import "Regex.xc"

enum _ValidKind = {VK_NONEMPTY, VK_MATCH, VK_MINLEN, VK_MAXLEN, VK_INTEGER, VK_NUMBER, VK_CUSTOM};

class _ValidRule
    {
    u8 kind;
    Regex* regex;
    i64 lo;
    i64 hi;
    double dlo;
    double dhi;
    callback check bool(String* text);
    String* message;
    }

class Validator
    {
    Array* _rules;

    void init(void)
        {
        _rules = new Array();
        }

    _ValidRule* _add(u8 kind, String* message)
        {
        _ValidRule* r = new _ValidRule();
        r.kind = kind;
        r.message = message == 0 ? String.withCString("") : message;
        _rules.add(r);
        return r;
        }

    // ── Rules ────────────────────────────────────────────────────────────

    // Something other than white space.
    void requireNonEmpty(String* message)
        {
        _add((u8)VK_NONEMPTY, message);
        }

    // The whole text matches `pattern`. Throws a RegexError for a bad one.
    void requireMatch(String* pattern, String* message) throws
        {
        Regex* re = Regex.compile(pattern);
        _add((u8)VK_MATCH, message).regex = re;
        }

    // The same with a Regex already compiled (with options, say).
    void requireRegex(Regex* re, String* message)
        {
        _add((u8)VK_MATCH, message).regex = re;
        }

    void requireMinLength(u32 n, String* message)
        {
        _add((u8)VK_MINLEN, message).lo = (i64)n;
        }

    void requireMaxLength(u32 n, String* message)
        {
        _add((u8)VK_MAXLEN, message).hi = (i64)n;
        }

    // A whole number from lo to hi.
    void requireIntegerRange(i64 lo, i64 hi, String* message)
        {
        _ValidRule* r = _add((u8)VK_INTEGER, message);
        r.lo = lo;
        r.hi = hi;
        }

    // Any number (integer or decimal) from lo to hi.
    void requireNumberRange(double lo, double hi, String* message)
        {
        _ValidRule* r = _add((u8)VK_NUMBER, message);
        r.dlo = lo;
        r.dhi = hi;
        }

    // `check` (a bound method or function) returns true for good text.
    void requireCustom(callback check bool(String* text), String* message)
        {
        _add((u8)VK_CUSTOM, message).check = check;
        }

    u32 ruleCount(void)
        {
        return _rules.count();
        }

    void removeAllRules(void)
        {
        _rules.removeAll();
        }

    // ── Checking ─────────────────────────────────────────────────────────

    // Whether `text` passes every rule.
    bool validate(String* text)
        {
        return firstError(text) == 0;
        }

    // The message of the first rule `text` fails, or null.
    String* firstError(String* text)
        {
        for (u32 i = (u32)0; i < _rules.count(); i++)
            {
            _ValidRule* r = (_ValidRule*)_rules.get(i);
            if (!Validator._passes(r, text))
                return r.message;
            }
        return (String*)0;
        }

    // The messages of every rule `text` fails, in order.
    Array* errors(String* text)
        {
        Array* out = new Array();
        for (u32 i = (u32)0; i < _rules.count(); i++)
            {
            _ValidRule* r = (_ValidRule*)_rules.get(i);
            if (!Validator._passes(r, text))
                out.add(r.message);
            }
        return out;
        }

    static Number* _number(String* s)
        {
        String* t = s.trimmed();
        if (t.byteLength() == (u32)0)
            return (Number*)0;
        try
            {
            return (Number* ?)JSON.parse(t);
            }
        catch (JSONError e)
            {
            }
        return (Number*)0;
        }

    static bool _passes(_ValidRule* r, String* text)
        {
        String* s = text == 0 ? String.withCString("") : text;
        u8 k = r.kind;
        if (k == (u8)VK_NONEMPTY)
            return s.trimmed().byteLength() > (u32)0;
        if (k == (u8)VK_MATCH)
            return r.regex.matches(s);
        if (k == (u8)VK_MINLEN)
            return (i64)s.charCount() >= r.lo;
        if (k == (u8)VK_MAXLEN)
            return (i64)s.charCount() <= r.hi;
        if (k == (u8)VK_INTEGER)
            {
            Number* n = Validator._number(s);
            if (n == 0 || n.isFloat() || n.isBool())
                return false;
            i64 v = n.asI64();
            return v >= r.lo && v <= r.hi;
            }
        if (k == (u8)VK_NUMBER)
            {
            Number* n = Validator._number(s);
            if (n == 0 || n.isBool())
                return false;
            double v = n.asDouble();
            return v >= r.dlo && v <= r.dhi;
            }
        callback c bool(String* text) = r.check;
        return !c || c(s);
        }
    }
