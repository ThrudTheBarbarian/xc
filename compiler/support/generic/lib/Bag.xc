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
// Bag.xc — a counted set (a multiset; CFBag / NSCountedSet in shape).
//
// Like a Set, but each member carries a COUNT: adding a member again raises its
// count, removing lowers it, and the member leaves at zero. totalCount is the
// sum of the counts, uniqueCount the number of distinct members.
//
// Membership is the Set's: a member's hash() picks its slot and equals()
// settles collisions. Object's own hash and equals are its identity, so a bag
// of plain objects counts references (a tally of tokens, "how many of these
// are selected"); a String or a Number is counted by value.
//
// Storage is Set's table with a count beside each key: open addressing with
// linear probing over a power-of-two capacity, tombstones on remove, and a
// dense insertion order, so memberAt(i) / countAt(i) are O(1) and walk the
// members in the order they first arrived. Counts are i32, indexes u32: no
// limit on the number of distinct members but memory.
//
// Heap-capable targets only.
#import "Hashable.xc"
#import "Comparable.xc"
#import "Enumerable.xc"
#import "Array.xc"

void _bag_arc_retain(pointer ptr)
    {
    __arc_retain(ptr);
    }

void _bag_arc_release(pointer ptr)
    {
    __arc_release(ptr);
    }

// A raw buffer from `new T[N]` is freed by releasing it to zero. Null-safe.
void _bag_buf_free(pointer buf)
    {
    __arc_release(buf);
    }

class Bag<Enumerable>
    {
    pointer* _slots; // capacity key cells: 0 empty, 1 tombstone, else a member
    i32* _counts;    // the count beside each occupied slot
    u32* _order;     // slot of each live member, in insertion order (dense)
    u32 _count;      // distinct members
    u32 _capacity;   // power of 2
    i32 _total;      // sum of the counts

    void init(void)
        {
        _slots = (pointer*)0;
        _counts = (i32*)0;
        _order = (u32*)0;
        _count = (u32)0;
        _capacity = (u32)0;
        _total = (i32)0;
        }

    void _growTo(u32 cap)
        {
        u32 c = (u32)16;
        while (c < cap)
            c = c * (u32)2;
        pointer* buf = new pointer[c];
        i32* cnt = new i32[c];
        for (u32 i = (u32)0; i < c; i = i + (u32)1)
            {
            buf[i] = (pointer)0;
            cnt[i] = (i32)0;
            }
        _slots = buf;
        _counts = cnt;
        _order = new u32[c];
        _capacity = c;
        }

    // Doubles the table and re-probes every live member (tombstones are not
    // carried across); each member keeps its count and its place in the order.
    void _resize(u32 newCap)
        {
        pointer* newBuf = new pointer[newCap];
        i32* newCnt = new i32[newCap];
        for (u32 i = (u32)0; i < newCap; i = i + (u32)1)
            {
            newBuf[i] = (pointer)0;
            newCnt[i] = (i32)0;
            }
        pointer* oldBuf = _slots;
        i32* oldCnt = _counts;
        u32* ord = _order;
        u32 newMask = newCap - (u32)1;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            u32 old = ord[i];
            pointer k = oldBuf[old];
            u32 probe = ((Hashable*)(Object*)k).hash() & newMask;
            for (u32 j = (u32)0; j < newCap; j = j + (u32)1)
                {
                u32 slot = (probe + j) & newMask;
                if (newBuf[slot] == (pointer)0)
                    {
                    newBuf[slot] = k;
                    newCnt[slot] = oldCnt[old];
                    ord[i] = slot;
                    break;
                    }
                }
            }
        _slots = newBuf;
        _counts = newCnt;
        _capacity = newCap;
        _bag_buf_free((pointer)oldBuf);
        _bag_buf_free((pointer)oldCnt);
        u32* grown = new u32[newCap];
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            grown[i] = ord[i];
        _order = grown;
        _bag_buf_free((pointer)ord);
        }

    // The member's slot, or (for a member not present) the slot an add would
    // use: the first tombstone on the probe chain, else the empty slot that
    // ended it. $FFFF_FFFF only when the table is full of tombstones.
    u32 _findSlot(Hashable* key)
        {
        u32 mask = _capacity - (u32)1;
        u32 firstTomb = $FFFF_FFFF;
        u32 probe = key.hash() & mask;
        pointer* b = _slots;
        for (u32 i = (u32)0; i < _capacity; i = i + (u32)1)
            {
            u32 slot = (probe + i) & mask;
            pointer k = b[slot];
            if (k == (pointer)0)
                return firstTomb != $FFFF_FFFF ? firstTomb : slot;
            if (k == (pointer)1)
                {
                if (firstTomb == $FFFF_FFFF)
                    firstTomb = slot;
                }
            else if (key.equals((Object*)k))
                return slot;
            }
        return firstTomb;
        }

    // The member's slot, or $FFFF_FFFF when it is not in the bag.
    u32 _slotOf(Object* o)
        {
        if (_count == (u32)0 || o == (Object*)0)
            return $FFFF_FFFF;
        u32 slot = _findSlot((Hashable*)o);
        if (slot == $FFFF_FFFF)
            return slot;
        pointer k = _key(slot);
        return (k == (pointer)0 || k == (pointer)1) ? $FFFF_FFFF : slot;
        }

    // Takes the member out of the table and the order (its count must
    // already be off _total).
    void _drop(u32 slot)
        {
        pointer k = _key(slot);
        _setKey(slot, (pointer)1);
        _setCnt(slot, (i32)0);
        u32* ord = _order;
        u32 oi = (u32)0;
        while (oi < _count && ord[oi] != slot)
            oi = oi + (u32)1;
        while (oi + (u32)1 < _count)
            {
            ord[oi] = ord[oi + (u32)1];
            oi = oi + (u32)1;
            }
        _count = _count - (u32)1;
        _bag_arc_release(k);
        }

    // Slot access through a local copy of the buffer pointer: subscripting
    // the ivar directly on a banked-heap target (xt6502) would index through
    // the receiver's bank window instead of the buffer's (see Set.xc).
    pointer _key(u32 i)
        {
        pointer* b = _slots;
        return b[i];
        }
    void _setKey(u32 i, pointer v)
        {
        pointer* b = _slots;
        b[i] = v;
        }
    i32 _cnt(u32 i)
        {
        i32* c = _counts;
        return c[i];
        }
    void _setCnt(u32 i, i32 v)
        {
        i32* c = _counts;
        c[i] = v;
        }

    // ── API ──────────────────────────────────────────────────────

    // One more of `o`.
    void add(Object* o)
        {
        addTimes(o, (i32)1);
        }

    // n more of `o` (nothing when n <= 0).
    void addTimes(Object* o, i32 n)
        {
        if (n <= (i32)0 || o == (Object*)0)
            return;
        if (_capacity == (u32)0)
            _growTo((u32)16);
        if ((_count + (u32)1) * (u32)4 > _capacity * (u32)3)
            _resize(_capacity * (u32)2);
        u32 slot = _findSlot((Hashable*)o);
        if (slot == $FFFF_FFFF)
            return;
        pointer k = _key(slot);
        if (k == (pointer)0 || k == (pointer)1)
            {
            _bag_arc_retain((pointer)o);
            _setKey(slot, (pointer)o);
            _setCnt(slot, n);
            u32* ord = _order;
            ord[_count] = slot;
            _count = _count + (u32)1;
            }
        else
            _setCnt(slot, _cnt(slot) + n);
        _total = _total + n;
        }

    // One fewer of `o`; it leaves the bag when its count reaches zero.
    void remove(Object* o)
        {
        u32 slot = _slotOf(o);
        if (slot == $FFFF_FFFF)
            return;
        _total = _total - (i32)1;
        _setCnt(slot, _cnt(slot) - (i32)1);
        if (_cnt(slot) <= (i32)0)
            _drop(slot);
        }

    // Every one of `o`.
    void removeAllOf(Object* o)
        {
        u32 slot = _slotOf(o);
        if (slot == $FFFF_FFFF)
            return;
        _total = _total - _cnt(slot);
        _drop(slot);
        }

    // Empty the bag.
    void removeAll(void)
        {
        for (u32 i = (u32)0; i < _capacity; i = i + (u32)1)
            {
            pointer k = _key(i);
            if (k != (pointer)0 && k != (pointer)1)
                _bag_arc_release(k);
            _setKey(i, (pointer)0);
            _setCnt(i, (i32)0);
            }
        _count = (u32)0;
        _total = (i32)0;
        }

    // How many of `o` (0 when it is not in the bag).
    i32 countFor(Object* o)
        {
        u32 slot = _slotOf(o);
        return slot == $FFFF_FFFF ? (i32)0 : _cnt(slot);
        }

    bool contains(Object* o)
        {
        return _slotOf(o) != $FFFF_FFFF;
        }

    // The sum of every member's count.
    i32 totalCount(void)
        {
        return _total;
        }

    // The number of distinct members.
    i32 uniqueCount(void)
        {
        return (i32)_count;
        }

    // The i-th distinct member, in the order members first arrived, and its
    // count; 0 past the end.
    Object* memberAt(i32 i)
        {
        if (i < (i32)0 || (u32)i >= _count)
            return (Object*)0;
        u32* ord = _order;
        return (Object*)_key(ord[i]);
        }

    i32 countAt(i32 i)
        {
        if (i < (i32)0 || (u32)i >= _count)
            return (i32)0;
        u32* ord = _order;
        return _cnt(ord[i]);
        }

    // ── Enumerable: the distinct members, in insertion order ─────
    u32 enumLength(void)
        {
        return _count;
        }

    Object* enumAt(u32 i)
        {
        return memberAt((i32)i);
        }

    void dealloc(void)
        {
        for (u32 i = (u32)0; i < _capacity; i = i + (u32)1)
            {
            pointer k = _key(i);
            if (k != (pointer)0 && k != (pointer)1)
                _bag_arc_release(k);
            }
        _bag_buf_free((pointer)_slots);
        _bag_buf_free((pointer)_counts);
        _bag_buf_free((pointer)_order);
        }
    }
