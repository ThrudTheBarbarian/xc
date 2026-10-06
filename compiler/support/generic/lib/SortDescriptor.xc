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
// SortDescriptor.xc — sort records by keys (NSSortDescriptor in shape).
// ===========================================================================
//
//     Array* byAge = SortDescriptor.sorted(people, SortDescriptor.list2(
//         SortDescriptor.withKey(String.withCString("age"), false),      // oldest first
//         SortDescriptor.withKey(String.withCString("name"), true)));    // then by name
//
// A descriptor names a key (a dotted path through nested Maps, as Predicate
// reads one), a direction, and whether Strings compare ignoring ASCII case.
// A list of them sorts by the first, then breaks ties with the next. Values
// order as Predicate compares them: Numbers as numbers (with Strings that
// hold numbers), Strings by bytes. A missing or null value, or one that has
// no order against the other, sorts before every other value when ascending.
//
// Sorting is stable: records that every descriptor finds equal keep their
// order. Filter with a Predicate, then sort with descriptors: what a table
// does to its rows.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every target except xt6502.

#if ARCH_6502
#error "SortDescriptor: not available on xt6502"
#endif

#import "Foundation.xc"
#import "Predicate.xc"

class SortDescriptor : Object
    {
    String* key;
    bool ascending;
    bool caseInsensitive;

    static SortDescriptor* withKey(String* key, bool ascending)
        {
        SortDescriptor* d = new SortDescriptor();
        d.key = key;
        d.ascending = ascending;
        return d;
        }

    // A list of one or two descriptors, for the common cases.
    static Array* list1(SortDescriptor* a)
        {
        Array* out = new Array();
        out.add(a);
        return out;
        }

    static Array* list2(SortDescriptor* a, SortDescriptor* b)
        {
        Array* out = SortDescriptor.list1(a);
        out.add(b);
        return out;
        }

    // A copy with the direction reversed: for a column header clicked again.
    SortDescriptor* reversed(void)
        {
        SortDescriptor* d = SortDescriptor.withKey(key, !ascending);
        d.caseInsensitive = caseInsensitive;
        return d;
        }

    // How two values order under this descriptor: -1, 0 or 1.
    i8 compareValues(Object* a, Object* b)
        {
        i32 c = Predicate.compareValues(a, b, caseInsensitive);
        if (c == (i32)2)
            {
            // No order: nothing first, then by whether there is a value.
            bool an = a == 0 || Null.isNull(a);
            bool bn = b == 0 || Null.isNull(b);
            c = an == bn ? (i32)0 : (an ? (i32)-1 : (i32)1);
            }
        if (!ascending)
            c = (i32)0 - c;
        return (i8)c;
        }

    // How two records order under this descriptor.
    i8 compare(Object* a, Object* b)
        {
        return compareValues(Predicate.valueAtPath(a, key), Predicate.valueAtPath(b, key));
        }

    // ── Sorting ──────────────────────────────────────────────────────────

    // A sorted copy of `items` (Maps), by `descriptors` in turn.
    static Array* sorted(Array* items, Array* descriptors)
        {
        _SortRun* run = new _SortRun();
        run.descriptors = descriptors;
        return run.sort(items);
        }

    // The same for any objects, reading each key through `read`.
    static Array* sortedWith(Array* items, Array* descriptors, callback read Object*(Object* item, String* key))
        {
        _SortRun* run = new _SortRun();
        run.descriptors = descriptors;
        run.read = read;
        return run.sort(items);
        }
    }

// One item with its original position, so equal items keep their order.
class _SortItem : Object
    {
    Object* item;
    u32 index;
    }

class _SortRun
    {
    Array* descriptors;
    callback read Object*(Object* item, String* key);

    Array* sort(Array* items)
        {
        Array* work = new Array();
        if (items == 0)
            return work;
        for (u32 i = (u32)0; i < items.count(); i++)
            {
            _SortItem* s = new _SortItem();
            s.item = items.get(i);
            s.index = i;
            work.add(s);
            }
        work.sortUsing(&self.cmp);
        Array* out = new Array();
        for (u32 i = (u32)0; i < work.count(); i++)
            out.add(((_SortItem*)work.get(i)).item);
        return out;
        }

    Object* value(Object* item, String* key)
        {
        callback r Object*(Object* item, String* key) = read;
        if (r)
            return r(item, key);
        return Predicate.valueAtPath(item, key);
        }

    i8 cmp(Object* a, Object* b)
        {
        _SortItem* x = (_SortItem*)a;
        _SortItem* y = (_SortItem*)b;
        if (descriptors != 0)
            {
            for (u32 k = (u32)0; k < descriptors.count(); k++)
                {
                SortDescriptor* d = (SortDescriptor*)descriptors.get(k);
                i8 c = d.compareValues(value(x.item, d.key), value(y.item, d.key));
                if (c != (i8)0)
                    return c;
                }
            }
        return x.index < y.index ? (i8)-1 : (x.index > y.index ? (i8)1 : (i8)0);
        }
    }
