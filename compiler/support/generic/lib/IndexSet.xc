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
// IndexSet.xc — a set of non-negative integer indexes, kept as ranges
// (NSIndexSet in shape).
// ===========================================================================
//
//     IndexSet* rows = new IndexSet();
//     rows.addRange(Range.make((i32)3, (i32)3));   // 3, 4, 5
//     rows.addIndex((i32)9);
//     rows.addIndex((i32)10);
//     rows.count();          // 5
//     rows.rangeCount();     // 2: [3,6) and [9,11)
//
// The indexes are stored as a sorted list of Ranges that neither overlap nor
// touch, so a block of a million rows costs one range; adding and removing
// merge and split ranges to keep it so. Finding the range for an index is a
// binary search. This is what a table's multi-row selection wants, and
// shiftIndexes keeps a selection right when rows are inserted or deleted.
//
// Indexes are i32 and at least 0. A method that finds an index returns
// IndexSet.notFound() (-1) when there is none.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every heap-capable target, the 6502 included.

#import "Foundation.xc"

#if ARCH_6502
#define _IS_N u16
#else
#define _IS_N u32
#endif

class IndexSet : Object
    {
    Array* _ranges;  // Range, sorted, neither overlapping nor touching

    void init(void)
        {
        _ranges = new Array();
        }

    static IndexSet* withIndex(i32 i)
        {
        IndexSet* s = new IndexSet();
        s.addIndex(i);
        return s;
        }

    static IndexSet* withRange(Range* r)
        {
        IndexSet* s = new IndexSet();
        s.addRange(r);
        return s;
        }

    static i32 notFound(void)
        {
        return (i32)-1;
        }

    Range* _at(_IS_N k)
        {
        return (Range*)_ranges.get(k);
        }

    // The first range whose end is past `i` (end > i), or the count if none.
    _IS_N _firstEndingAfter(i32 i)
        {
        _IS_N lo = (_IS_N)0;
        _IS_N hi = _ranges.count();
        while (lo < hi)
            {
            _IS_N mid = lo + (hi - lo) / (_IS_N)2;
            if (_at(mid).end() > i)
                hi = mid;
            else
                lo = mid + (_IS_N)1;
            }
        return lo;
        }

    // ── Adding ───────────────────────────────────────────────────────────

    void addIndex(i32 i)
        {
        _add(i, (i32)1);
        }

    void addRange(Range* r)
        {
        if (r != 0)
            _add(r.loc, r.len);
        }

    void addIndexes(IndexSet* other)
        {
        if (other == 0 || other == self)
            return;
        for (_IS_N k = (_IS_N)0; k < other._ranges.count(); k++)
            addRange(other._at(k));
        }

    void _add(i32 loc, i32 len)
        {
        if (len <= (i32)0)
            return;
        if (loc < (i32)0)
            {
            len = len + loc;
            loc = (i32)0;
            if (len <= (i32)0)
                return;
            }
        i32 s = loc;
        i32 e = loc + len;
        // A range that ends exactly at s touches it, so start one earlier.
        _IS_N a = s > (i32)0 ? _firstEndingAfter(s - (i32)1) : (_IS_N)0;
        while (a < _ranges.count() && _at(a).loc <= e)
            {
            Range* r = _at(a);
            if (r.loc < s)
                s = r.loc;
            if (r.end() > e)
                e = r.end();
            _ranges.removeAt(a);
            }
        _ranges.insert(a, Range.make(s, e - s));
        }

    // ── Removing ─────────────────────────────────────────────────────────

    void removeIndex(i32 i)
        {
        _remove(i, (i32)1);
        }

    void removeRange(Range* r)
        {
        if (r != 0)
            _remove(r.loc, r.len);
        }

    void removeIndexes(IndexSet* other)
        {
        if (other == 0)
            return;
        if (other == self)
            {
            removeAllIndexes();
            return;
            }
        for (_IS_N k = (_IS_N)0; k < other._ranges.count(); k++)
            removeRange(other._at(k));
        }

    void removeAllIndexes(void)
        {
        _ranges.removeAll();
        }

    void _remove(i32 loc, i32 len)
        {
        if (len <= (i32)0)
            return;
        i32 s = loc;
        i32 e = loc + len;
        _IS_N a = _firstEndingAfter(s);
        while (a < _ranges.count())
            {
            Range* r = _at(a);
            if (r.loc >= e)
                break;
            i32 rEnd = r.end();
            if (r.loc < s && rEnd > e)
                {
                // The removal is inside this range: split it.
                r.len = s - r.loc;
                _ranges.insert(a + (_IS_N)1, Range.make(e, rEnd - e));
                return;
                }
            if (r.loc < s)
                {
                r.len = s - r.loc;
                a++;
                }
            else if (rEnd > e)
                {
                r.loc = e;
                r.len = rEnd - e;
                return;
                }
            else
                _ranges.removeAt(a);
            }
        }

    // ── Testing ──────────────────────────────────────────────────────────

    bool containsIndex(i32 i)
        {
        _IS_N a = _firstEndingAfter(i);
        return a < _ranges.count() && _at(a).loc <= i;
        }

    // Whether every index of `r` is in the set (an empty range: true).
    bool containsRange(Range* r)
        {
        if (r == 0 || r.len <= (i32)0)
            return true;
        _IS_N a = _firstEndingAfter(r.loc);
        return a < _ranges.count() && _at(a).loc <= r.loc && _at(a).end() >= r.end();
        }

    bool containsIndexes(IndexSet* other)
        {
        if (other == 0)
            return true;
        for (_IS_N k = (_IS_N)0; k < other._ranges.count(); k++)
            {
            if (!containsRange(other._at(k)))
                return false;
            }
        return true;
        }

    // Whether any index of `r` is in the set.
    bool intersectsRange(Range* r)
        {
        if (r == 0 || r.len <= (i32)0)
            return false;
        _IS_N a = _firstEndingAfter(r.loc);
        return a < _ranges.count() && _at(a).loc < r.end();
        }

    // ── Counting and finding ─────────────────────────────────────────────

    // The number of indexes (not ranges).
    u32 count(void)
        {
        u32 n = (u32)0;
        for (_IS_N k = (_IS_N)0; k < _ranges.count(); k++)
            n = n + (u32)_at(k).len;
        return n;
        }

    bool isEmpty(void)
        {
        return _ranges.count() == (_IS_N)0;
        }

    i32 firstIndex(void)
        {
        return isEmpty() ? IndexSet.notFound() : _at((_IS_N)0).loc;
        }

    i32 lastIndex(void)
        {
        return isEmpty() ? IndexSet.notFound() : _at(_ranges.count() - (_IS_N)1).end() - (i32)1;
        }

    // The smallest index greater than `i`, or notFound().
    i32 indexGreaterThan(i32 i)
        {
        return indexGreaterThanOrEqualTo(i + (i32)1);
        }

    i32 indexGreaterThanOrEqualTo(i32 i)
        {
        _IS_N a = _firstEndingAfter(i);
        if (a >= _ranges.count())
            return IndexSet.notFound();
        Range* r = _at(a);
        return r.loc > i ? r.loc : i;
        }

    // The largest index less than `i`, or notFound().
    i32 indexLessThan(i32 i)
        {
        return indexLessThanOrEqualTo(i - (i32)1);
        }

    i32 indexLessThanOrEqualTo(i32 i)
        {
        if (i < (i32)0)
            return IndexSet.notFound();
        _IS_N a = _firstEndingAfter(i);
        if (a < _ranges.count() && _at(a).loc <= i)
            return i;
        if (a == (_IS_N)0)
            return IndexSet.notFound();
        return _at(a - (_IS_N)1).end() - (i32)1;
        }

    // ── Ranges ───────────────────────────────────────────────────────────

    u32 rangeCount(void)
        {
        return (u32)_ranges.count();
        }

    // A copy of the k-th range, in order.
    Range* rangeAt(u32 k)
        {
        Range* r = _at((_IS_N)k);
        return Range.make(r.loc, r.len);
        }

    // ── Shifting ─────────────────────────────────────────────────────────

    // Moves every index at or after `start` by `delta`, as when rows are
    // inserted (delta > 0: a gap opens at start) or deleted (delta < 0: the
    // indexes in [start + delta, start) go and the rest close up).
    void shiftIndexes(i32 start, i32 delta)
        {
        if (delta == (i32)0)
            return;
        if (delta < (i32)0)
            {
            i32 gone = start + delta;
            _remove(gone, (i32)0 - delta);
            }
        Array* old = _ranges;
        _ranges = new Array();
        for (_IS_N k = (_IS_N)0; k < old.count(); k++)
            {
            Range* r = (Range*)old.get(k);
            i32 rEnd = r.end();
            if (rEnd <= start)
                _add(r.loc, r.len);
            else if (r.loc >= start)
                _add(r.loc + delta, r.len);
            else
                {
                _add(r.loc, start - r.loc);
                _add(start + delta, rEnd - start);
                }
            }
        }

    // ── Object ───────────────────────────────────────────────────────────

    IndexSet* copy(void)
        {
        IndexSet* c = new IndexSet();
        for (_IS_N k = (_IS_N)0; k < _ranges.count(); k++)
            {
            Range* r = _at(k);
            c._ranges.add(Range.make(r.loc, r.len));
            }
        return c;
        }

    bool equals(Object* other)
        {
        IndexSet* o = (IndexSet* ?)other;
        if (o == 0 || o._ranges.count() != _ranges.count())
            return false;
        for (_IS_N k = (_IS_N)0; k < _ranges.count(); k++)
            {
            if (!_at(k).equals(o._at(k)))
                return false;
            }
        return true;
        }

#if ARCH_6502
    u8 hash(void)
        {
        u8 h = (u8)_ranges.count();
        for (_IS_N k = (_IS_N)0; k < _ranges.count(); k++)
            h = h * (u8)31 + _at(k).hash();
        return h;
        }
#else
    u32 hash(void)
        {
        u32 h = (u32)_ranges.count();
        for (_IS_N k = (_IS_N)0; k < _ranges.count(); k++)
            h = h * (u32)31 + _at(k).hash();
        return h;
        }
#endif

    // "(3-5, 9, 10-12)", for printing.
    String* description(void)
        {
        String* s = String.withCString("(");
        for (_IS_N k = (_IS_N)0; k < _ranges.count(); k++)
            {
            Range* r = _at(k);
            if (k > (_IS_N)0)
                s.appendCString(", ");
            s.append(Number.withI32(r.loc).description());
            if (r.len > (i32)1)
                {
                s.appendCString("-");
                s.append(Number.withI32(r.end() - (i32)1).description());
                }
            }
        s.appendCString(")");
        return s;
        }
    }
