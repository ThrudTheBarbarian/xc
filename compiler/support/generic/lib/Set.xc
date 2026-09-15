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

// Set.xc — NSMutableSet-style hash set keyed by any Hashable +
// Comparable Object*.
//
// Storage is a single heap-allocated pointer buffer, one cell
// per slot. Open addressing with linear probing. Capacity is always a
// power of two — so `hash & (cap - 1)` is the initial probe — and is
// bounded only by memory. It used to be capped at 256, which was never a
// design choice: it was the 8-bit hash domain, above which the high slots
// were unreachable. The hash is u32 here.
//
// Slot states are encoded in the key cell:
//   * empty     — key == 0              (zero page, never a heap addr)
//   * tombstone — key == 1              (placeholder after remove)
//   * occupied  — key is a heap pointer (>= 2 in practice)
//
// Probe rules mirror Map's:
//   * lookup walks until either the matching element or an empty
//     slot — tombstones are skipped, NOT terminating.
//   * insert reuses the FIRST tombstone seen on the probe chain
//     before the empty slot, keeping clusters short across
//     repeated add/remove cycles.
//   * remove plants a tombstone instead of clearing.
//
// Elements must conform to Hashable (for slot selection) and
// Comparable (for collision-chain equality). Foundation's
// Number / String / Data conform to both out of the box.
//
// Heap-capable targets only.

#import "Hashable.xc"
#import "Copying.xc"
#import "Comparable.xc"
#import "Enumerable.xc"
#import "Array.xc"

// File-scope helpers that retain / release a stored element pointer.
// Mirrors Map.xc's `_map_arc_retain` / `_map_arc_release` shape — see the
// header comment there. Both forward to the `__arc_retain` / `__arc_release`
// language primitives, so they behave identically on both backends (arm64
// genuinely retains and frees; xt6502 routes through the real free-list
// ARC). The old inline-asm bodies were no-ops on the arm64 backend.

void _set_arc_retain(pointer ptr)
    {
    __arc_retain(ptr);
    }

void _set_arc_release(pointer ptr)
    {
    __arc_release(ptr);
    }

// Free a raw slot buffer. `new pointer[N]` comes from the same allocator as
// any object — a heap header with refcount 1 and no destructor — so releasing
// it to zero reclaims it. One primitive, correct on every backend.
//
// This used to be a body of `asm { #if ARCH_6502 ... }`, which freed nothing
// at all on the four non-6502 backends: the table leaked on every rehash and
// again on drop. Null-safe.
void _set_slots_free(pointer* buf)
    {
    __arc_release((pointer)buf);
    }

void _set_order_free(u32* buf)
    {
    __arc_release((pointer)buf);
    }

class Set<Enumerable, Copying>
    {
    pointer* _slots; // capacity pointer cells
    u32 _count;      // live entries (excludes tombstones)
    u32 _capacity;   // power of 2, bounded only by memory

    // Insertion order — see the long note in Map.xc. `_order[0.._count-1]` holds
    // the SLOT INDEX of each live element in insertion order, so iteration is
    // deterministic (slot order is hash order, and Object's default hash is
    // address-derived) and enumAt(i) is O(1) for any access pattern. Dense:
    // remove() closes the gap, which it must, since _findSlot hands a tombstoned
    // slot to the next add and a stale entry would then alias a different element.
    u32* _order;

    void init(void)
        {
        _slots = (pointer*)0;
        _order = (u32*)0;
        _count = (u32)0;
        _capacity = (u32)0;
        }

    // Any mutation may move entries, so a slot remembered before it means
    // nothing after.
    // Allocate the slot buffer at the given (rounded-up power-of-2,
    // ≥ 16) capacity.
    static Set* withCapacity(u32 cap)
        {
        Set* s = new Set();
        s._growTo(cap);
        return s;
        }

    void _growTo(u32 cap)
        {
        u32 c = (u32)16;
        while (c < cap)
            c = c * (u32)2;
        pointer* buf = new pointer[c];
        for (u32 i = (u32)0; i < c; i = i + (u32)1)
            {
            buf[i] = (pointer)0;
            }
        _slots = buf;
        _order = new u32[c];
        _capacity = c;
        }

    // Geometric grow at α > 0.75 — the table doubles, every live
    // entry is re-probed into the larger buffer, the old buffer is
    // freed. Tombstones are NOT carried across.
    void _resize(u32 newCap)
        {
        pointer* newBuf = new pointer[newCap];
        for (u32 i = (u32)0; i < newCap; i = i + (u32)1)
            {
            newBuf[i] = (pointer)0;
            }
        // Rehash the order array IN PLACE — see Map.xc: a second order array live
        // alongside both slot buffers exhausted the 6502 harness heap. Grown below,
        // after the old slot buffer is freed.
        u32* ord = _order;
        u32 newMask = newCap - (u32)1;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            pointer k = _readKey(ord[i]);
            pointer kTag = k;
            if (kTag == (pointer)0 || kTag == (pointer)1)
                continue; // defensive
            u32 h = ((Hashable*)(Object*)k).hash();
            u32 probe = h & newMask;
            for (u32 j = (u32)0; j < newCap; j = j + (u32)1)
                {
                u32 slot = (probe + j) & newMask;
                pointer keyPtr = newBuf[slot];
                if (keyPtr == (pointer)0)
                    {
                    newBuf[slot] = k;
                    ord[i] = slot;
                    break;
                    }
                }
            }

        pointer* oldBuf = _slots;
        _slots = newBuf;
        _capacity = newCap;
        _set_slots_free(oldBuf);

        // Grow the order array only now — the old slot buffer is already freed.
        u32* grown = new u32[newCap];
        u32* cur = _order;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            grown[i] = cur[i];
        _order = grown;
        _set_order_free(cur);
        }

    // ── Slot byte access ─────────────────────────────────────────
    // Each accessor routes through a local copy of the heap pointer
    // — direct ivar subscript through (self),Y on a banked-heap
    // target with the heap bank live would land on the receiver's
    // bank window byte instead of the payload.
    pointer _readKey(u32 idx)
        {
        pointer* b = _slots;
        return b[idx];
        }

    void _writeKey(u32 idx, pointer ptr)
        {
        pointer* b = _slots;
        b[idx] = ptr;
        }

    // ── Probe ────────────────────────────────────────────────────
    u32 _findSlot(Hashable* key)
        {
        u32 h = key.hash();
        u32 mask = _capacity - (u32)1;
        u32 firstTomb = $FFFF_FFFF;
        u32 probe = h & mask;
        for (u32 i = (u32)0; i < _capacity; i = i + (u32)1)
            {
            u32 slot = (probe + i) & mask;
            pointer keyPtr = _readKey(slot);
            if (keyPtr == (pointer)0)
                {
                if (firstTomb != $FFFF_FFFF)
                    return firstTomb;
                return slot;
                }
            if (keyPtr == (pointer)1)
                {
                if (firstTomb == $FFFF_FFFF)
                    firstTomb = slot;
                }
            else
                {
                Object* storedObj = (Object*)keyPtr;
                if (key.equals(storedObj))
                    {
                    return slot;
                    }
                }
            }
        return firstTomb;
        }

    // ── API ──────────────────────────────────────────────────────
    void add(Hashable* elem)
        {
        if (_capacity == (u32)0)
            _growTo((u32)16);
        u32 lhs = (_count + (u32)1) * (u32)4;
        u32 rhs = _capacity * (u32)3;
        if (lhs > rhs)
            _resize(_capacity * (u32)2);
        u32 slot = _findSlot(elem);
        if (slot == $FFFF_FFFF)
            return; // shouldn't happen pre-resize
        pointer existing = _readKey(slot);
        bool fresh = (existing == (pointer)0) || (existing == (pointer)1);
        if (!fresh)
            {
            // Re-add of an existing element is a no-op for membership;
            // skip the retain/release to avoid needless heap traffic.
            return;
            }
        _set_arc_retain((pointer)elem);
        _writeKey(slot, (pointer)elem);
        // New element goes on the end of the insertion order; _count is the next
        // free order index because _order is kept dense.
        u32* ord = _order;
        ord[_count] = slot;
        _count = _count + (u32)1;
        }

    bool contains(Hashable* elem)
        {
        if (_count == (u32)0)
            return false;
        u32 slot = _findSlot(elem);
        if (slot == $FFFF_FFFF)
            return false;
        pointer kTag = _readKey(slot);
        bool r;
        if (kTag == (pointer)0 || kTag == (pointer)1)
            {
            r = false;
            }
        else
            {
            r = true;
            }
        return r;
        }

    void remove(Hashable* elem)
        {
        if (_count == (u32)0)
            return;
        u32 slot = _findSlot(elem);
        if (slot == $FFFF_FFFF)
            return;
        pointer k = _readKey(slot);
        if (k == (pointer)0 || k == (pointer)1)
            return; // not present
        // Plant tombstone first, then drop strong ref.
        _writeKey(slot, (pointer)1);

        // Close the gap in _order — it must stay dense (see the ivar note):
        // _findSlot hands this tombstoned slot to the next add, so a stale entry
        // would later alias a different element and iteration would yield it twice.
        u32* ord = _order;
        u32 oi = (u32)0;
        while (oi < _count)
            {
            if (ord[oi] == slot)
                break;
            oi = oi + (u32)1;
            }
        while (oi + (u32)1 < _count)
            {
            ord[oi] = ord[oi + (u32)1];
            oi = oi + (u32)1;
            }

        _count = _count - (u32)1;
        _set_arc_release(k);
        }

    void removeAll(void)
        {
        if (_capacity == (u32)0)
            return;
        for (u32 i = (u32)0; i < _capacity; i = i + (u32)1)
            {
            pointer k = _readKey(i);
            pointer kTag = k;
            if (kTag == (pointer)0 || kTag == (pointer)1)
                continue;
            _writeKey(i, (pointer)0);
            _set_arc_release(k);
            }
        _count = (u32)0;
        }

    u32 count(void)
        {
        return _count;
        }
    bool isEmpty(void)
        {
        return _count == (u32)0;
        }

    // ── Enumerable conformance ───────────────────────────────────
    u32 enumLength(void)
        {
        return _count;
        }

    Object* enumAt(u32 i)
        {
        // A plain index: _order is dense and in insertion order.
        if (i >= _count)
            return (Object*)0;
        u32* ord = _order;
        return (Object*)_readKey(ord[i]);
        }

    // ── Set algebra ──────────────────────────────────────────────
    // Each returns a NEW Set; the receiver and the argument are untouched. The
    // results hold their own strong reference to every element they contain, as
    // any Set does.
    //
    // These are the operations that make a Set worth having over an Array: "who
    // is in both", "who is new", "who went away".

    // Everything in either.
    Set* unionWith(Set* other)
        {
        Set* out = new Set();
        for (Object* e in self)
            {
            if (e != 0)
                out.add((Hashable*)e);
            }
        if (other != 0)
            {
            for (Object* e in other)
                {
                if (e != 0)
                    out.add((Hashable*)e);
                }
            }
        return out;
        }

    // Only what is in BOTH.
    Set* intersect(Set* other)
        {
        Set* out = new Set();
        if (other == 0)
            return out;
        for (Object* e in self)
            {
            if (e != 0 && other.contains((Hashable*)e))
                out.add((Hashable*)e);
            }
        return out;
        }

    // In the receiver but not in `other`.
    Set* subtract(Set* other)
        {
        Set* out = new Set();
        for (Object* e in self)
            {
            if (e == 0)
                continue;
            if (other == 0 || !other.contains((Hashable*)e))
                out.add((Hashable*)e);
            }
        return out;
        }

    // In one or the other, but not both.
    Set* symmetricDifference(Set* other)
        {
        Set* out = subtract(other);
        if (other != 0)
            {
            for (Object* e in other)
                {
                if (e != 0 && !contains((Hashable*)e))
                    out.add((Hashable*)e);
                }
            }
        return out;
        }

    // ── Relations ────────────────────────────────────────────────
    bool isSubsetOf(Set* other)
        {
        if (other == 0)
            return _count == (u32)0;
        for (Object* e in self)
            {
            if (e != 0 && !other.contains((Hashable*)e))
                return false;
            }
        return true;
        }

    bool isSupersetOf(Set* other)
        {
        if (other == 0)
            return true;
        return other.isSubsetOf(self);
        }

    bool intersects(Set* other)
        {
        if (other == 0)
            return false;
        for (Object* e in self)
            {
            if (e != 0 && other.contains((Hashable*)e))
                return true;
            }
        return false;
        }

    bool isDisjointFrom(Set* other)
        {
        return !intersects(other);
        }

    // Same members, in any order.
    bool equalsSet(Set* other)
        {
        if (other == 0)
            return _count == (u32)0;
        if (_count != other.count())
            return false;
        return isSubsetOf(other);
        }

    // ── Conversion ───────────────────────────────────────────────
    // Members as an Array, in iteration order (which is the table's order, not
    // insertion order — a Set has none).
    Array* allObjects(void)
        {
        Array* out = Array.withCapacity(_count);
        for (Object* e in self)
            {
            if (e != 0)
                out.add(e);
            }
        return out;
        }

    static Set* withArray(Array* items)
        {
        Set* out = new Set();
        if (items == 0)
            return out;
        for (Object* e in items)
            {
            if (e != 0)
                out.add((Hashable*)e);
            }
        return out;
        }

    // ── Destruction ──────────────────────────────────────────────
    void dealloc(void)
        {
        u32 i = (u32)0;
        while (i < _capacity)
            {
            pointer k = _readKey(i);
            pointer kTag = k;
            if (kTag != (pointer)0 && kTag != (pointer)1)
                {
                _set_arc_release(k);
                }
            i = i + (u32)1;
            }
        _set_slots_free(_slots);
        _set_order_free(_order);
        }

    // <Copying>: a new Set holding the same elements. SHALLOW — the elements
    // are shared, each retained by the new Set so both own independently.
    Set* copy(void)
        {
        return Set.withArray(allObjects());
        }
    }
