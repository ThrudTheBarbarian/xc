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
// members in the order they first arrived.
//
// ── xt6502 build of this class ───────────────────────────────────────────
// The 6502 Foundation's widths, as Set's: indexes and lengths u16, the hash u8
// (one heap block is capped at a 12 KB bank, so a table never needs more).
// The 32-bit machines use support/generic/lib/Bag.xc.
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
    u16* _order;     // slot of each live member, in insertion order (dense)
    u16 _count;      // distinct members
    u16 _capacity;   // power of 2
    i32 _total;      // sum of the counts

    void init(void)
        {
        _slots = (pointer*)0;
        _counts = (i32*)0;
        _order = (u16*)0;
        _count = (u16)0;
        _capacity = (u16)0;
        _total = (i32)0;
        }

    void _growTo(u16 cap)
        {
        u16 c = (u16)16;
        while (c < cap)
            c = c * (u16)2;
        pointer* buf = new pointer[c];
        i32* cnt = new i32[c];
        for (u16 i = (u16)0; i < c; i = i + (u16)1)
            {
            buf[i] = (pointer)0;
            cnt[i] = (i32)0;
            }
        _slots = buf;
        _counts = cnt;
        _order = new u16[c];
        _capacity = c;
        }

    // Doubles the table and re-probes every live member (tombstones are not
    // carried across); each member keeps its count and its place in the order.
    void _resize(u16 newCap)
        {
        pointer* newBuf = new pointer[newCap];
        i32* newCnt = new i32[newCap];
        for (u16 i = (u16)0; i < newCap; i = i + (u16)1)
            {
            newBuf[i] = (pointer)0;
            newCnt[i] = (i32)0;
            }
        pointer* oldBuf = _slots;
        i32* oldCnt = _counts;
        u16* ord = _order;
        u16 newMask = newCap - (u16)1;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            u16 old = ord[i];
            pointer k = oldBuf[old];
            u16 probe = ((Hashable*)(Object*)k).hash() & newMask;
            for (u16 j = (u16)0; j < newCap; j = j + (u16)1)
                {
                u16 slot = (probe + j) & newMask;
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
        u16* grown = new u16[newCap];
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            grown[i] = ord[i];
        _order = grown;
        _bag_buf_free((pointer)ord);
        }

    // The member's slot, or (for a member not present) the slot an add would
    // use: the first tombstone on the probe chain, else the empty slot that
    // ended it. $FFFF only when the table is full of tombstones.
    u16 _findSlot(Hashable* key)
        {
        u16 mask = _capacity - (u16)1;
        u16 firstTomb = $FFFF;
        u16 probe = key.hash() & mask;
        pointer* b = _slots;
        for (u16 i = (u16)0; i < _capacity; i = i + (u16)1)
            {
            u16 slot = (probe + i) & mask;
            pointer k = b[slot];
            if (k == (pointer)0)
                return firstTomb != $FFFF ? firstTomb : slot;
            if (k == (pointer)1)
                {
                if (firstTomb == $FFFF)
                    firstTomb = slot;
                }
            else if (key.equals((Object*)k))
                return slot;
            }
        return firstTomb;
        }

    // The member's slot, or $FFFF when it is not in the bag.
    u16 _slotOf(Object* o)
        {
        if (_count == (u16)0 || o == (Object*)0)
            return $FFFF;
        u16 slot = _findSlot((Hashable*)o);
        if (slot == $FFFF)
            return slot;
        pointer k = _key(slot);
        return (k == (pointer)0 || k == (pointer)1) ? $FFFF : slot;
        }

    // Takes the member out of the table and the order (its count must
    // already be off _total).
    void _drop(u16 slot)
        {
        pointer k = _key(slot);
        _setKey(slot, (pointer)1);
        _setCnt(slot, (i32)0);
        u16* ord = _order;
        u16 oi = (u16)0;
        while (oi < _count && ord[oi] != slot)
            oi = oi + (u16)1;
        while (oi + (u16)1 < _count)
            {
            ord[oi] = ord[oi + (u16)1];
            oi = oi + (u16)1;
            }
        _count = _count - (u16)1;
        _bag_arc_release(k);
        }

    // Slot access through a local copy of the buffer pointer: subscripting
    // the ivar directly on a banked-heap target (xt6502) would index through
    // the receiver's bank window instead of the buffer's (see Set.xc).
    pointer _key(u16 i)
        {
        pointer* b = _slots;
        return b[i];
        }
    void _setKey(u16 i, pointer v)
        {
        pointer* b = _slots;
        b[i] = v;
        }
    i32 _cnt(u16 i)
        {
        i32* c = _counts;
        return c[i];
        }
    void _setCnt(u16 i, i32 v)
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
        if (_capacity == (u16)0)
            _growTo((u16)16);
        if ((_count + (u16)1) * (u16)4 > _capacity * (u16)3)
            _resize(_capacity * (u16)2);
        u16 slot = _findSlot((Hashable*)o);
        if (slot == $FFFF)
            return;
        pointer k = _key(slot);
        if (k == (pointer)0 || k == (pointer)1)
            {
            _bag_arc_retain((pointer)o);
            _setKey(slot, (pointer)o);
            _setCnt(slot, n);
            u16* ord = _order;
            ord[_count] = slot;
            _count = _count + (u16)1;
            }
        else
            _setCnt(slot, _cnt(slot) + n);
        _total = _total + n;
        }

    // One fewer of `o`; it leaves the bag when its count reaches zero.
    void remove(Object* o)
        {
        u16 slot = _slotOf(o);
        if (slot == $FFFF)
            return;
        _total = _total - (i32)1;
        _setCnt(slot, _cnt(slot) - (i32)1);
        if (_cnt(slot) <= (i32)0)
            _drop(slot);
        }

    // Every one of `o`.
    void removeAllOf(Object* o)
        {
        u16 slot = _slotOf(o);
        if (slot == $FFFF)
            return;
        _total = _total - _cnt(slot);
        _drop(slot);
        }

    // Empty the bag.
    void removeAll(void)
        {
        for (u16 i = (u16)0; i < _capacity; i = i + (u16)1)
            {
            pointer k = _key(i);
            if (k != (pointer)0 && k != (pointer)1)
                _bag_arc_release(k);
            _setKey(i, (pointer)0);
            _setCnt(i, (i32)0);
            }
        _count = (u16)0;
        _total = (i32)0;
        }

    // How many of `o` (0 when it is not in the bag).
    i32 countFor(Object* o)
        {
        u16 slot = _slotOf(o);
        return slot == $FFFF ? (i32)0 : _cnt(slot);
        }

    bool contains(Object* o)
        {
        return _slotOf(o) != $FFFF;
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
        if (i < (i32)0 || (u16)i >= _count)
            return (Object*)0;
        u16* ord = _order;
        return (Object*)_key(ord[i]);
        }

    i32 countAt(i32 i)
        {
        if (i < (i32)0 || (u16)i >= _count)
            return (i32)0;
        u16* ord = _order;
        return _cnt(ord[i]);
        }

    // ── Enumerable: the distinct members, in insertion order ─────
    u16 enumLength(void)
        {
        return _count;
        }

    Object* enumAt(u16 i)
        {
        return memberAt((i32)i);
        }

    void dealloc(void)
        {
        for (u16 i = (u16)0; i < _capacity; i = i + (u16)1)
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
