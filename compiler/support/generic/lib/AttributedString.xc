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
// AttributedString.xc — text with named attributes over ranges of it
// (NSAttributedString in shape).
// ===========================================================================
//
//     AttributedString* s = AttributedString.withString(String.withCString("Hello, world"));
//     s.setAttribute(String.withCString("bold"), Number.withBool(true), Range.make((i32)0, (i32)5));
//     s.runCount();     // 2: "Hello" bold, ", world" plain
//
// Attributes are named by Strings and hold any object: a font, a colour, a
// link, a flag. Which names mean what is up to the code that draws the text;
// Foundation only keeps them. Positions and ranges are byte offsets into the
// UTF-8 text.
//
// The text is covered by runs: ranges whose characters share one set of
// attributes, with neighbours that have equal sets merged, so drawing can
// walk the runs and style one span at a time. Two sets are equal when they
// have the same names and their values are equal by `equals`.
//
// Editing the text keeps the attributes where they belong: replaced text
// takes the attributes of the first byte it replaces; inserted text takes
// those of the byte before it (of the first byte, at the start); text after
// the edit moves with it.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every heap-capable target except xt6502.

#if ARCH_6502
#error "AttributedString: not available on xt6502"
#endif

#import "Foundation.xc"

class _AttrRun
    {
    i32 loc;
    i32 len;
    Map* attrs;  // String name -> Object; never shared between runs
    }

class AttributedString : Object
    {
    String* _text;
    Array* _runs;  // _AttrRun, covering [0, length) in order; none when empty

    void init(void)
        {
        _text = String.withCString("");
        _runs = new Array();
        }

    static AttributedString* withString(String* text)
        {
        AttributedString* a = new AttributedString();
        a._text = text == 0 ? String.withCString("") : String.withString(text);
        a._resetRuns();
        return a;
        }

    // `text` with `attrs` over all of it.
    static AttributedString* withAttributes(String* text, Map* attrs)
        {
        AttributedString* a = AttributedString.withString(text);
        if (attrs != 0)
            a.addAttributes(attrs, Range.make((i32)0, a.length()));
        return a;
        }

    void _resetRuns(void)
        {
        _runs = new Array();
        if (_text.byteLength() > (u32)0)
            _runs.add(AttributedString._run((i32)0, (i32)_text.byteLength(), new Map()));
        }

    static _AttrRun* _run(i32 loc, i32 len, Map* attrs)
        {
        _AttrRun* r = new _AttrRun();
        r.loc = loc;
        r.len = len;
        r.attrs = attrs;
        return r;
        }

    // ── The text ─────────────────────────────────────────────────────────

    // A copy of the text.
    String* text(void)
        {
        return String.withString(_text);
        }

    // The length in bytes.
    i32 length(void)
        {
        return (i32)_text.byteLength();
        }

    // ── Reading attributes ───────────────────────────────────────────────

    u32 _runIndexAt(i32 at)
        {
        u32 lo = (u32)0;
        u32 hi = _runs.count();
        while (lo < hi)
            {
            u32 mid = lo + (hi - lo) / (u32)2;
            _AttrRun* r = (_AttrRun*)_runs.get(mid);
            if (r.loc + r.len > at)
                hi = mid;
            else
                lo = mid + (u32)1;
            }
        return lo;
        }

    // A copy of the attributes at byte `at`; empty out of range.
    Map* attributesAt(i32 at)
        {
        if (at < (i32)0 || at >= length())
            return new Map();
        return ((_AttrRun*)_runs.get(_runIndexAt(at))).attrs.copy();
        }

    // The value of `name` at byte `at`, or null.
    Object* attribute(String* name, i32 at)
        {
        if (at < (i32)0 || at >= length() || name == 0)
            return (Object*)0;
        return ((_AttrRun*)_runs.get(_runIndexAt(at))).attrs.get(name);
        }

    // The run holding byte `at`: the longest range around it with the same
    // attributes. An empty range at `at` when out of range.
    Range* runRangeAt(i32 at)
        {
        if (at < (i32)0 || at >= length())
            return Range.make(at, (i32)0);
        _AttrRun* r = (_AttrRun*)_runs.get(_runIndexAt(at));
        return Range.make(r.loc, r.len);
        }

    u32 runCount(void)
        {
        return _runs.count();
        }

    // The k-th run's range and a copy of its attributes, in order.
    Range* runRange(u32 k)
        {
        _AttrRun* r = (_AttrRun*)_runs.get(k);
        return Range.make(r.loc, r.len);
        }

    Map* runAttributes(u32 k)
        {
        return ((_AttrRun*)_runs.get(k)).attrs.copy();
        }

    // ── Changing attributes ──────────────────────────────────────────────

    // Sets `name` to `value` over `r` (a null value removes it).
    void setAttribute(String* name, Object* value, Range* r)
        {
        if (name == 0)
            return;
        Map* one = new Map();
        if (value != 0)
            one.set(name, value);
        _apply(one, name, r);
        }

    void removeAttribute(String* name, Range* r)
        {
        setAttribute(name, (Object*)0, r);
        }

    // Sets every attribute of `attrs` over `r`, leaving the others.
    void addAttributes(Map* attrs, Range* r)
        {
        if (attrs == 0)
            return;
        _apply(attrs, (String*)0, r);
        }

    // Replaces every attribute over `r` with `attrs` (null: none).
    void setAttributes(Map* attrs, Range* r)
        {
        i32 s;
        i32 e;
        if (!_clip(r, &s, &e))
            return;
        _splitAt(s);
        _splitAt(e);
        for (u32 k = _runIndexAt(s); k < _runs.count(); k++)
            {
            _AttrRun* run = (_AttrRun*)_runs.get(k);
            if (run.loc >= e)
                break;
            run.attrs = attrs == 0 ? new Map() : attrs.copy();
            }
        _merge();
        }

    bool _clip(Range* r, i32* s, i32* e)
        {
        if (r == 0)
            return false;
        i32 a = r.loc < (i32)0 ? (i32)0 : r.loc;
        i32 b = r.end() > length() ? length() : r.end();
        *s = a;
        *e = b;
        return b > a;
        }

    // `set` over the clipped range; `removing`, if not null, is a name that
    // `set` leaves out and is to be removed.
    void _apply(Map* set, String* removing, Range* r)
        {
        i32 s;
        i32 e;
        if (!_clip(r, &s, &e))
            return;
        _splitAt(s);
        _splitAt(e);
        for (u32 k = _runIndexAt(s); k < _runs.count(); k++)
            {
            _AttrRun* run = (_AttrRun*)_runs.get(k);
            if (run.loc >= e)
                break;
            if (removing != 0 && !set.contains(removing))
                run.attrs.remove(removing);
            for (u32 i = (u32)0; i < set.count(); i++)
                {
                Hashable* key = (Hashable*)set.enumAt(i);
                run.attrs.set(key, set.get(key));
                }
            }
        _merge();
        }

    // Makes a run boundary at `at` (if inside the text and not one already).
    void _splitAt(i32 at)
        {
        if (at <= (i32)0 || at >= length())
            return;
        u32 k = _runIndexAt(at);
        _AttrRun* r = (_AttrRun*)_runs.get(k);
        if (r.loc == at)
            return;
        i32 end = r.loc + r.len;
        r.len = at - r.loc;
        _runs.insert(k + (u32)1, AttributedString._run(at, end - at, r.attrs.copy()));
        }

    // Merges neighbouring runs with equal attributes.
    void _merge(void)
        {
        u32 k = (u32)1;
        while (k < _runs.count())
            {
            _AttrRun* a = (_AttrRun*)_runs.get(k - (u32)1);
            _AttrRun* b = (_AttrRun*)_runs.get(k);
            if (AttributedString._same(a.attrs, b.attrs))
                {
                a.len = a.len + b.len;
                _runs.removeAt(k);
                }
            else
                k++;
            }
        }

    static bool _same(Map* a, Map* b)
        {
        if (a.count() != b.count())
            return false;
        for (u32 i = (u32)0; i < a.count(); i++)
            {
            Hashable* key = (Hashable*)a.enumAt(i);
            Object* va = a.get(key);
            Object* vb = b.get(key);
            if (vb == 0 || !b.contains(key))
                return false;
            if (va != vb && (va == 0 || !va.equals(vb)))
                return false;
            }
        return true;
        }

    // ── Editing the text ─────────────────────────────────────────────────

    // Replaces the bytes of `r` with `text`, which takes the attributes of the
    // first byte replaced; inserted text takes those of the byte before it (of
    // the first byte at the start, none in an empty string).
    void replace(Range* r, String* text)
        {
        AttributedString* plain = AttributedString.withString(text);
        i32 s = r == 0 ? length() : (r.loc < (i32)0 ? (i32)0 : (r.loc > length() ? length() : r.loc));
        i32 e = r == 0 ? s : (r.end() > length() ? length() : r.end());
        if (e < s)
            e = s;
        Map* attrs;
        if (e > s)
            attrs = attributesAt(s);
        else if (s > (i32)0)
            attrs = attributesAt(s - (i32)1);
        else
            attrs = attributesAt((i32)0);
        plain.setAttributes(attrs, Range.make((i32)0, plain.length()));
        _splice(s, e, plain);
        }

    // Replaces the bytes of `r` with `other`, keeping other's attributes.
    void replaceWithAttributed(Range* r, AttributedString* other)
        {
        i32 s = r.loc < (i32)0 ? (i32)0 : (r.loc > length() ? length() : r.loc);
        i32 e = r.end() > length() ? length() : r.end();
        if (e < s)
            e = s;
        _splice(s, e, other == 0 ? new AttributedString() : other);
        }

    // Adds `text` at the end, with the attributes of the last byte.
    void appendString(String* text)
        {
        replace(Range.make(length(), (i32)0), text);
        }

    void append(AttributedString* other)
        {
        replaceWithAttributed(Range.make(length(), (i32)0), other);
        }

    void _splice(i32 s, i32 e, AttributedString* mid)
        {
        String* t = _text.substringBytes((u32)0, (u32)s);
        t.append(mid._text);
        t.append(_text.substringFromByte((u32)e));
        Array* runs = new Array();
        i32 shift = mid.length() - (e - s);
        for (u32 k = (u32)0; k < _runs.count(); k++)
            {
            _AttrRun* r = (_AttrRun*)_runs.get(k);
            i32 rEnd = r.loc + r.len;
            if (r.loc < s)
                {
                i32 keep = (rEnd < s ? rEnd : s) - r.loc;
                runs.add(AttributedString._run(r.loc, keep, r.attrs));
                }
            }
        for (u32 k = (u32)0; k < mid._runs.count(); k++)
            {
            _AttrRun* r = (_AttrRun*)mid._runs.get(k);
            runs.add(AttributedString._run(r.loc + s, r.len, r.attrs.copy()));
            }
        for (u32 k = (u32)0; k < _runs.count(); k++)
            {
            _AttrRun* r = (_AttrRun*)_runs.get(k);
            i32 rEnd = r.loc + r.len;
            if (rEnd > e)
                {
                i32 from = r.loc > e ? r.loc : e;
                runs.add(AttributedString._run(from + shift, rEnd - from, r.attrs.copy()));
                }
            }
        _text = t;
        _runs = runs;
        _merge();
        }

    // ── Pieces ───────────────────────────────────────────────────────────

    // The text and attributes of `r` (clipped to the text).
    AttributedString* substring(Range* r)
        {
        i32 s;
        i32 e;
        AttributedString* out = new AttributedString();
        if (!_clip(r, &s, &e))
            return out;
        out._text = _text.substringBytes((u32)s, (u32)(e - s));
        for (u32 k = _runIndexAt(s); k < _runs.count(); k++)
            {
            _AttrRun* run = (_AttrRun*)_runs.get(k);
            if (run.loc >= e)
                break;
            i32 a = run.loc > s ? run.loc : s;
            i32 b = run.loc + run.len < e ? run.loc + run.len : e;
            out._runs.add(AttributedString._run(a - s, b - a, run.attrs.copy()));
            }
        return out;
        }

    AttributedString* copy(void)
        {
        return substring(Range.make((i32)0, length()));
        }

    // Equal text, and equal attributes over the same runs.
    bool equals(Object* other)
        {
        AttributedString* o = (AttributedString* ?)other;
        if (o == 0 || !o._text.equals(_text) || o._runs.count() != _runs.count())
            return false;
        for (u32 k = (u32)0; k < _runs.count(); k++)
            {
            _AttrRun* a = (_AttrRun*)_runs.get(k);
            _AttrRun* b = (_AttrRun*)o._runs.get(k);
            if (a.loc != b.loc || a.len != b.len || !AttributedString._same(a.attrs, b.attrs))
                return false;
            }
        return true;
        }

    u32 hash(void)
        {
        return _text.hash();
        }

    // The text.
    String* description(void)
        {
        return text();
        }
    }
