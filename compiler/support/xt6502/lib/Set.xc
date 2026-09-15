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
// were unreachable. The hash is u16 here.
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
//
// ── xt6502 build of this class ───────────────────────────────────────────
// The 6502 Foundation. Counts, indices and lengths are u16 and the hash is
// u8, because on an 8-bit CPU a 32-bit index is four bytes of arithmetic on
// every compare and every increment, and a container that could address more
// than 65535 elements could not fit them anyway — one heap block is capped
// at a 12 KB bank. The 32-bit machines (arm64, arm9, m68k, x86_64) use
// `support/generic/lib/` instead, which is uncapped and hashes 32-bit.
//
// Same API, different implementation. Neither target pays for the other's
// constraints.
//
// Only the files whose WIDTHS differ live here. Everything width-neutral —
// Object, Comparable, Sort, the Foundation umbrella — exists once, in
// generic/lib, and is shared: a library file's `#import "X.xc"` resolves
// through the platform's lib dir first and generic/lib second, never against
// its own directory. So generic/lib/Object.xc picks up THIS String and THIS
// Hashable when the target is the 6502.
//

#import "Hashable.xc"
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

// Free a raw slot buffer — straight `_heap_free`, no refcount and no
// destructor dispatch. That distinction matters on this target: a raw
// `new pointer[N]` block carries no destructor descriptor, so routing it
// through the ARC release path (which dispatches one) walks into garbage.
// The 32-bit Foundation can use `__arc_release` here; the 6502 cannot.
// Null-safe.
// Free a raw u16 order buffer. Like the slot buffer (and String's byte buffer),
// this is a RAW allocation with no destructor descriptor — and on this build the
// ARC release path dispatches one, so __arc_release corrupts the heap here. It
// has to go straight to _heap_free. Getting this wrong did not fail loudly: the
// first free "succeeded", the free list was left corrupt, and the NEXT
// allocation returned a bad pointer that the program later jumped through.
// Null-safe.
void _set_order_free(u16* buf)
    {
    asm {
#if ARCH_6502
        LDA buf
        LDX buf+1
        ORA buf+1
        BEQ .setord_done
        LDA buf
        LDX buf+1
#if XTC_POINTER_WIDTH == 3
        LDY buf+2
#elif XTC_POINTER_WIDTH == 4
        LDA buf+3
        STA $89
        LDA buf
        LDX buf+1
        LDY buf+2
#else
        LDY #heap_bank_first
#endif
        JSR _heap_free
.setord_done:
#endif
    }
    }

void _set_slots_free(pointer* buf)
    {
    asm {
#if ARCH_6502
        LDA buf
        LDX buf+1
        ORA buf+1
        BEQ .sbf_done
        LDA buf
        LDX buf+1
#if XTC_POINTER_WIDTH == 3
        LDY buf+2
#elif XTC_POINTER_WIDTH == 4
        LDA buf+3
        STA $89
        LDA buf
        LDX buf+1
        LDY buf+2
#else
        LDY #heap_bank_first
#endif
        JSR _heap_free
.sbf_done:
#endif
    }
    }

class Set<Enumerable>
    {
    pointer* _slots; // capacity pointer cells
    u16 _count;      // live entries (excludes tombstones)
    u16 _capacity;   // power of 2, bounded only by memory

    // Insertion order — see the note in this build's Map.xc. Dense array of slot
    // indices; iteration walks it so order is deterministic (slot order is hash
    // order, and Object's default hash is address-derived) and enumAt(i) is O(1).
    u16* _order;

    void init(void)
        {
        _slots = (pointer*)0;
        _order = (u16*)0;
        _count = (u16)0;
        _capacity = (u16)0;
        }

    // Any mutation may move entries, so a slot remembered before it means
    // nothing after.
    // Allocate the slot buffer at the given (rounded-up power-of-2,
    // ≥ 16) capacity.
    static Set* withCapacity(u16 cap)
        {
        Set* s = new Set();
        s._growTo(cap);
        return s;
        }

    void _growTo(u16 cap)
        {
        u16 c = (u16)16;
        while (c < cap)
            c = c * (u16)2;
        pointer* buf = new pointer[c];
        for (u16 i = (u16)0; i < c; i = i + (u16)1)
            {
            buf[i] = (pointer)0;
            }
        _slots = buf;
        _order = new u16[c];
        _capacity = c;
        }

    // Geometric grow at α > 0.75 — the table doubles, every live
    // entry is re-probed into the larger buffer, the old buffer is
    // freed. Tombstones are NOT carried across.
    void _resize(u16 newCap)
        {
        pointer* newBuf = new pointer[newCap];
        for (u16 i = (u16)0; i < newCap; i = i + (u16)1)
            {
            newBuf[i] = (pointer)0;
            }

        // Rehash the order array IN PLACE — see Map.xc: a second order array live
        // alongside both slot buffers exhausted the 6502 harness heap. Grown below,
        // after the old slot buffer is freed.
        u16* ord = _order;
        u16 newMask = newCap - (u16)1;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            pointer k = _readKey(ord[i]);
            pointer kTag = k;
            if (kTag == (pointer)0 || kTag == (pointer)1)
                continue; // defensive
            u8 h = ((Hashable*)(Object*)k).hash();
            u16 probe = ((u16)h) & newMask;
            for (u16 j = (u16)0; j < newCap; j = j + (u16)1)
                {
                u16 slot = (probe + j) & newMask;
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
        u16* grown = new u16[newCap];
        u16* cur = _order;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            grown[i] = cur[i];
        _order = grown;
        _set_order_free(cur);
        }

    // ── Slot byte access ─────────────────────────────────────────
    // Each accessor routes through a local copy of the heap pointer
    // — direct ivar subscript through (self),Y on a banked-heap
    // target with the heap bank live would land on the receiver's
    // bank window byte instead of the payload.
    pointer _readKey(u16 idx)
        {
        pointer* b = _slots;
        return b[idx];
        }

    void _writeKey(u16 idx, pointer ptr)
        {
        pointer* b = _slots;
        b[idx] = ptr;
        }

    // ── Probe ────────────────────────────────────────────────────
    u16 _findSlot(Hashable* key)
        {
        u8 h = key.hash();
        u16 mask = _capacity - (u16)1;
        u16 firstTomb = $FFFF;
        u16 probe = ((u16)h) & mask;
        for (u16 i = (u16)0; i < _capacity; i = i + (u16)1)
            {
            u16 slot = (probe + i) & mask;
            pointer keyPtr = _readKey(slot);
            if (keyPtr == (pointer)0)
                {
                if (firstTomb != $FFFF)
                    return firstTomb;
                return slot;
                }
            if (keyPtr == (pointer)1)
                {
                if (firstTomb == $FFFF)
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
        if (_capacity == (u16)0)
            _growTo((u16)16);
        u16 lhs = (_count + (u16)1) * (u16)4;
        u16 rhs = _capacity * (u16)3;
        if (lhs > rhs)
            _resize(_capacity * (u16)2);
        u16 slot = _findSlot(elem);
        if (slot == $FFFF)
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
        // New element goes on the end of the insertion order.
        u16* ord = _order;
        ord[_count] = slot;
        _count = _count + (u16)1;
        }

    bool contains(Hashable* elem)
        {
        if (_count == (u16)0)
            return false;
        u16 slot = _findSlot(elem);
        if (slot == $FFFF)
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
        if (_count == (u16)0)
            return;
        u16 slot = _findSlot(elem);
        if (slot == $FFFF)
            return;
        pointer k = _readKey(slot);
        if (k == (pointer)0 || k == (pointer)1)
            return; // not present
        // Plant tombstone first, then drop strong ref.
        _writeKey(slot, (pointer)1);

        // Close the gap in _order — it must stay dense (see Map.xc).
        u16* ord = _order;
        u16 oi = (u16)0;
        while (oi < _count)
            {
            if (ord[oi] == slot)
                break;
            oi = oi + (u16)1;
            }
        while (oi + (u16)1 < _count)
            {
            ord[oi] = ord[oi + (u16)1];
            oi = oi + (u16)1;
            }

        _count = _count - (u16)1;
        _set_arc_release(k);
        }

    void removeAll(void)
        {
        if (_capacity == (u16)0)
            return;
        for (u16 i = (u16)0; i < _capacity; i = i + (u16)1)
            {
            pointer k = _readKey(i);
            pointer kTag = k;
            if (kTag == (pointer)0 || kTag == (pointer)1)
                continue;
            _writeKey(i, (pointer)0);
            _set_arc_release(k);
            }
        _count = (u16)0;
        }

    u16 count(void)
        {
        return _count;
        }
    bool isEmpty(void)
        {
        return _count == (u16)0;
        }

    // ── Enumerable conformance ───────────────────────────────────
    u16 enumLength(void)
        {
        return _count;
        }

    Object* enumAt(u16 i)
        {
        // A plain index: _order is dense and in insertion order.
        if (i >= _count)
            return (Object*)0;
        u16* ord = _order;
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
            return _count == (u16)0;
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
            return _count == (u16)0;
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
        u16 i = (u16)0;
        while (i < _capacity)
            {
            pointer k = _readKey(i);
            pointer kTag = k;
            if (kTag != (pointer)0 && kTag != (pointer)1)
                {
                _set_arc_release(k);
                }
            i = i + (u16)1;
            }
        _set_slots_free(_slots);
        _set_order_free(_order);
        }
    }
