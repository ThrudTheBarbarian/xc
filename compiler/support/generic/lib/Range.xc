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
// Range.xc — a half-open range of indexes [loc, loc + len) (NSRange in shape).
//
// A class rather than a struct so ranges can live in an Array, a Set or a
// Map: a wrapped line, a selected block of rows and a run of styled characters
// are each a list of ranges.
//
// Half-open is the contract: `loc` is in the range and `end()` is not, an
// empty range has len 0, and adjacent ranges meet with a.end() == b.loc, no
// gap and no overlap. Two ranges are equal when their loc and len are; the
// hash agrees, so a range works as a Set member or a Map key by value.
#import "Object.xc"

class Range : Object
    {
    i32 loc;
    i32 len;

    void init(void)
        {
        loc = (i32)0;
        len = (i32)0;
        }

    static Range* make(i32 l, i32 n)
        {
        Range* r = new Range();
        r.loc = l;
        r.len = n;
        return r;
        }

    // One past the last index.
    i32 end(void)
        {
        return loc + len;
        }

    bool isEmpty(void)
        {
        return len <= (i32)0;
        }

    bool contains(i32 i)
        {
        return i >= loc && i < loc + len;
        }

    // Whether the two cover an index in common. Ranges that only touch end to
    // end ([0,3) and [3,5)) do not overlap, and an empty range overlaps nothing,
    // even a range it sits inside.
    bool overlaps(Range* o)
        {
        if (o == (Range*)0 || isEmpty() || o.isEmpty())
            return false;
        return loc < o.end() && o.loc < end();
        }

    // The indexes both cover, or an empty range at the later start when they
    // share none.
    Range* intersection(Range* o)
        {
        if (o == (Range*)0)
            return Range.make(loc, (i32)0);
        i32 a = loc > o.loc ? loc : o.loc;
        i32 b = end() < o.end() ? end() : o.end();
        return Range.make(a, b > a ? b - a : (i32)0);
        }

    // The smallest range covering both (including any gap between them).
    Range* unionWith(Range* o)
        {
        if (o == (Range*)0 || o.isEmpty())
            return Range.make(loc, len);
        if (isEmpty())
            return Range.make(o.loc, o.len);
        i32 a = loc < o.loc ? loc : o.loc;
        i32 b = end() > o.end() ? end() : o.end();
        return Range.make(a, b - a);
        }

    bool equals(Object* other)
        {
        Range* o = (Range* ?)other;
        return o != (Range*)0 && o.loc == loc && o.len == len;
        }

#if ARCH_6502
    u8 hash(void)
        {
        return (u8)((u32)loc ^ ((u32)len << 3) ^ ((u32)loc >> 8));
        }
#else
    u32 hash(void)
        {
        u32 v = (u32)loc * (u32)2654435761 ^ (u32)len;
        v = v ^ (v >> 15);
        return v;
        }
#endif
    }
