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

// Map.xc — NSMutableDictionary-style hash map keyed by any
// Hashable + Comparable Object*.
//
// Storage is a single heap-allocated pointer buffer, two cells
// per slot (key, value). At width=2 each cell is 2 bytes; at
// width=3 each cell is 3 bytes (lo, hi, bank). Open addressing
// with linear probing. Capacity is always a power of two and
// bounded only by memory — the hash is u32 — so `hash & (cap - 1)`
// is the initial probe and the cap fits in u32 with room to spare.
//
// Slot states are encoded in the key cell:
//   * empty     — key == 0              (zero page, never a heap addr)
//   * tombstone — key == 1              (placeholder after remove)
//   * occupied  — key is a heap pointer (>= 2 in practice)
//
// Probe rules:
//   * lookup walks until either the matching key or an empty slot
//     — tombstones are skipped, NOT terminating, so a chain that
//     was lengthened by an insert past a deleted entry still
//     resolves correctly.
//   * insert reuses the FIRST tombstone seen on the probe chain
//     before the empty slot, keeping clusters short across
//     repeated set/remove cycles.
//   * remove plants a tombstone instead of clearing — same
//     reason: don't break later entries' probe chains.
//
// Keys must conform to Hashable (for slot selection) and
// Comparable (for collision-chain equality). Values are plain
// Object*. Foundation's Number / String / Data conform to both
// out of the box; user types add `<Hashable, Comparable>` to
// the class line and supply the two methods.
//
// Heap-capable targets only.

#import "Hashable.xc"
#import "Copying.xc"
#import "Comparable.xc"
#import "Enumerable.xc"
#import "Array.xc"

// File-scope helpers that retain / release a stored element pointer.
// Mirrors Array.xc's `_array_arc_retain` / `_array_arc_release` shape.
//
// Both forward to the `__arc_retain` / `__arc_release` language primitives
// — the sanctioned manual-refcount path for the type-erased `pointer` slots
// ARC can't see. Each lowers to the same Retain / Release the compiler
// inserts for typed strong refs (null-safe, bank-carrying), so they behave
// identically on both backends: arm64 genuinely retains AND frees its
// elements (no leak), and xt6502 routes through the real free-list ARC. The
// previous inline-6502-asm bodies were no-ops on the arm64 backend, so the
// Map's keys/values were never retained or freed there.

void _map_arc_retain(pointer ptr)
    {
    __arc_retain(ptr);
    }

void _map_arc_release(pointer ptr)
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
void _map_slots_free(pointer* buf)
    {
    __arc_release((pointer)buf);
    }

void _map_order_free(u32* buf)
    {
    __arc_release((pointer)buf);
    }

class Map<Enumerable, Copying>
    {
    pointer* _slots; // capacity * 2 pointer cells (key, value)
    u32 _count;      // live entries (excludes tombstones)
    u32 _capacity;   // power of 2, bounded only by memory

    // ── Insertion order ──────────────────────────────────────────
    // `_order[0.._count-1]` holds the SLOT INDEX of each live entry, in the
    // order the keys were first inserted. Iteration walks this rather than the
    // slot table, which buys three things:
    //
    //  * **Deterministic iteration.** Slot order is hash order, and the default
    //    Object.hash is derived from the object's ADDRESS — so a map keyed by
    //    user objects used to enumerate in heap-layout order, differing between
    //    runs. Anything ordered that way reaching a compiler's output makes a
    //    3-stage bootstrap's stage2 and stage3 differ intermittently. See
    //    private:docs/Design/self-hosting.md §5.
    //  * **enumAt(i) is O(1)** — a direct index, for ANY access pattern. It used
    //    to rescan the slot table counting live entries, which a cursor patched
    //    down to O(capacity) for strictly sequential walks only; a nested loop
    //    over the same map, or any random index, still fell back to the full
    //    scan and made the walk O(n²). The cursor is gone with the need for it.
    //  * **Iteration is O(count), not O(capacity)**, over a dense contiguous
    //    array instead of a strided scan across a table that is 1.33–2.67× the
    //    live-entry count.
    //
    // Invariant: `_order` is dense — exactly `_count` valid entries, no holes.
    // That is what makes enumAt a plain index, and it is why remove() has to
    // close the gap (below). Sized to `_capacity`, so it never needs a growth
    // path of its own: count can never exceed 0.75*capacity.
    u32* _order;

    void init(void)
        {
        _slots = (pointer*)0;
        _order = (u32*)0;
        _count = (u32)0;
        _capacity = (u32)0;
        }

    // Allocate the slot buffer at the given (rounded-up power-of-2,
    // ≥ 16) capacity. The caller can pre-size when the rough
    // upper bound is known to skip a future resize copy. Bare
    // `new Map()` lazily allocates on the first set().
    static Map* withCapacity(u32 cap)
        {
        Map* m = new Map();
        m._growTo(cap);
        return m;
        }

    // Round `cap` up to the next power-of-2 (≥ 16), allocate
    // the slot buffer, zero-fill it (the (pointer)0 zero-bit pattern
    // marks every slot empty). Used by withCapacity and the first
    // set() call (lazy initial allocation).
    void _growTo(u32 cap)
        {
        u32 c = (u32)16;
        while (c < cap)
            c = c * (u32)2;
        pointer* buf = new pointer[c * (u32)2];
        // new u8/pointer[N] returns zero-cleared bytes from the
        // heap allocator already; explicit zero-fill is a paranoia
        // hedge against any future allocator change.
        for (u32 i = (u32)0; i < c * (u32)2; i = i + (u32)1)
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
    //
    // Refcounts don't move during resize. Each (key, value) pointer
    // is just relocated from one buffer to the other; the receiver
    // (heap object) sees no retain/release. _map_slots_free on the
    // old buffer reclaims only the slot bytes — never the pointed-
    // to objects.
    void _resize(u32 newCap)
        {
        pointer* newBuf = new pointer[newCap * (u32)2];
        for (u32 i = (u32)0; i < newCap * (u32)2; i = i + (u32)1)
            {
            newBuf[i] = (pointer)0;
            }
        // Rehash the order array IN PLACE rather than allocating a second one.
        // Peak heap during a resize is what matters here: the old and new slot
        // buffers are both live for the duration, and on a 6502 harness heap
        // (~6KB) holding two order arrays on top of that was enough to exhaust
        // it — the 64->128 resize died. In place, only one order array exists at
        // a time, and it is grown further down once the OLD SLOT BUFFER HAS BEEN
        // FREED, so the two large allocations never overlap with the two small
        // ones.
        //
        // Writing in place is safe: entry i is read before it is written, and
        // _order is sized to the OLD capacity while holding only
        // _count <= 0.75*oldCapacity entries.
        // (Tombstones are not carried across — they hold no live entry and so
        // appear nowhere in _order.)
        u32* ord = _order;
        u32 newMask = newCap - (u32)1;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            u32 oldSlot = ord[i];
            pointer k = _readKey(oldSlot);
            if (k == (pointer)0 || k == (pointer)1)
                continue; // defensive
            pointer v = _readVal(oldSlot);
            // Linear-probe insert into newBuf, fully inlined.
            u32 h = ((Hashable*)(Object*)k).hash();
            u32 probe = h & newMask;
            for (u32 j = (u32)0; j < newCap; j = j + (u32)1)
                {
                u32 slot = (probe + j) & newMask;
                u32 base = slot * (u32)2;
                pointer keyPtr = newBuf[base];
                if (keyPtr == (pointer)0)
                    {
                    newBuf[base] = k;
                    newBuf[base + (u32)1] = v;
                    ord[i] = slot;
                    break;
                    }
                }
            }

        pointer* oldBuf = _slots;
        _slots = newBuf;
        _capacity = newCap;
        _map_slots_free(oldBuf);

        // Only NOW grow the order array — the old slot buffer is already gone, so
        // this small pair never coexists with the large pair.
        u32* grown = new u32[newCap];
        u32* cur = _order;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            grown[i] = cur[i];
        _order = grown;
        _map_order_free(cur);
        }

    // ── Slot byte access ─────────────────────────────────────────
    // Each accessor routes through a local copy of the heap pointer
    // — direct ivar subscript through (self),Y on a banked-heap
    // target lands on the receiver's bank window byte instead of
    // the payload. The local-load shape shifts the indirect through
    // zpTmp where the bank-bracketed load helper kicks in.
    pointer _readKey(u32 idx)
        {
        pointer* b = _slots;
        return b[idx * (u32)2];
        }

    pointer _readVal(u32 idx)
        {
        pointer* b = _slots;
        return b[idx * (u32)2 + (u32)1];
        }

    void _writeKey(u32 idx, pointer ptr)
        {
        pointer* b = _slots;
        b[idx * (u32)2] = ptr;
        }

    void _writeVal(u32 idx, pointer ptr)
        {
        pointer* b = _slots;
        b[idx * (u32)2 + (u32)1] = ptr;
        }

    // ── Probe ────────────────────────────────────────────────────
    // Walk the probe chain for `key`. Returns the slot index of
    // either an existing match (so callers can read or overwrite)
    // or a free slot the caller can insert into. Free means: the
    // first tombstone seen on the chain if any, else the first
    // empty slot. $FFFF_FFFF means "table exhausted" (every slot is a
    // live non-match) — only happens when count == capacity, which
    // the resize path will keep us out of.
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
                // Empty — terminate.
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
                // Equality dispatch: call .equals() on the NEW key
                // with the stored key as Object*.
                Object* storedObj = (Object*)keyPtr;
                if (key.equals(storedObj))
                    {
                    return slot;
                    }
                }
            }
        // Table exhausted (only reachable pre-resize at α == 1).
        return firstTomb;
        }

    // ── API ──────────────────────────────────────────────────────
    void set(Hashable* key, Object* value)
        {
        if (_capacity == (u32)0)
            _growTo((u32)16);
        // α > 0.75 trigger: 4*(count + 1) > 3*capacity.
        u32 lhs = (_count + (u32)1) * (u32)4;
        u32 rhs = _capacity * (u32)3;
        if (lhs > rhs)
            _resize(_capacity * (u32)2);
        u32 slot = _findSlot(key);
        if (slot == $FFFF_FFFF)
            return; // shouldn't happen pre-resize
        pointer existingKey = _readKey(slot);
        bool fresh = (existingKey == (pointer)0) || (existingKey == (pointer)1);
        if (!fresh)
            {
            // Overwriting a live entry: drop the old key+value
            // before retaining the new pair.
            pointer oldVal = _readVal(slot);
            _map_arc_retain((pointer)key);
            _map_arc_retain((pointer)value);
            _map_arc_release(existingKey);
            _map_arc_release(oldVal);
            }
        else
            {
            _map_arc_retain((pointer)key);
            _map_arc_retain((pointer)value);
            }
        _writeKey(slot, (pointer)key);
        _writeVal(slot, (pointer)value);
        if (fresh)
            {
            // A new key goes on the end of the insertion order. _count is the
            // next free order index precisely because _order is kept dense.
            u32* ord = _order;
            ord[_count] = slot;
            _count = _count + (u32)1;
            }
        }

    Object* get(Hashable* key)
        {
        if (_count == (u32)0)
            return (Object*)0;
        u32 slot = _findSlot(key);
        if (slot == $FFFF_FFFF)
            return (Object*)0;
        pointer k = _readKey(slot);
        pointer kTag = k;
        if (kTag == (pointer)0 || kTag == (pointer)1)
            return (Object*)0;
        return (Object*)_readVal(slot);
        }

    bool contains(Hashable* key)
        {
        return get(key) != (Object*)0;
        }

    void remove(Hashable* key)
        {
        if (_count == (u32)0)
            return;
        u32 slot = _findSlot(key);
        if (slot == $FFFF_FFFF)
            return;
        pointer k = _readKey(slot);
        pointer kTag = k;
        if (kTag == (pointer)0 || kTag == (pointer)1)
            return; // not present
        pointer v = _readVal(slot);
        // Plant tombstone first, then drop strong refs.
        _writeKey(slot, (pointer)1);
        _writeVal(slot, (pointer)0);

        // Close the gap in _order. This is the one operation the insertion-order
        // array makes more expensive — O(count) rather than O(1) — and it CANNOT
        // be deferred by leaving a hole: _findSlot hands a tombstoned slot to the
        // next insert, so a stale order entry would later point at a slot holding
        // a DIFFERENT key, and iteration would yield that key twice. Density is
        // also what keeps enumAt a plain index.
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
        _map_arc_release(k);
        _map_arc_release(v);
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
            pointer v = _readVal(i);
            _writeKey(i, (pointer)0);
            _writeVal(i, (pointer)0);
            _map_arc_release(k);
            _map_arc_release(v);
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

    // ── Views ────────────────────────────────────────────────────
    // `contains` asks whether the KEY is present, which is not the same
    // question as "is get(k) non-null" — a key stored with a null value is
    // still a key. It used to be written as `get(key) != 0`, which answered the
    // wrong one.
    bool containsKey(Hashable* key)
        {
        if (_count == (u32)0)
            return false;
        u32 slot = _findSlot(key);
        if (slot == $FFFF_FFFF)
            return false;
        pointer k = _readKey(slot);
        return k != (pointer)0 && k != (pointer)1;
        }

    // In insertion order — see _order. Deterministic between runs, which raw
    // slot order was not.
    Array* allKeys(void)
        {
        Array* out = Array.withCapacity(_count);
        u32* ord = _order;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            out.add((Object*)_readKey(ord[i]));
            }
        return out;
        }

    // In insertion order, matching allKeys index for index.
    Array* allValues(void)
        {
        Array* out = Array.withCapacity(_count);
        u32* ord = _order;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            out.add((Object*)_readVal(ord[i]));
            }
        return out;
        }

    // The value for `key`, or `fallback` when the key is absent. Saves the
    // caller a null test in the common "settings with defaults" shape.
    Object* getOrDefault(Hashable* key, Object* fallback)
        {
        if (!containsKey(key))
            return fallback;
        return get(key);
        }

    // ── Enumerable conformance ───────────────────────────────────
    // for-in yields the map's KEYS (the typical Foundation /
    // NSDictionary semantic — the user calls `m.get(k)` for the
    // matching value), in INSERTION order. enumLength == count, so the
    // for-in driver iterates exactly _count times.
    u32 enumLength(void)
        {
        return _count;
        }

    Object* enumAt(u32 i)
        {
        // A plain index: _order is dense and in insertion order, so the i'th
        // key is one lookup away regardless of access pattern.
        if (i >= _count)
            return (Object*)0;
        u32* ord = _order;
        return (Object*)_readKey(ord[i]);
        }

    // ── Destruction ──────────────────────────────────────────────
    // Walk the slot table releasing every live key+value pair, then
    // free the slot buffer.
    void dealloc(void)
        {
        u32 i = (u32)0;
        while (i < _capacity)
            {
            pointer k = _readKey(i);
            pointer kTag = k;
            if (kTag != (pointer)0 && kTag != (pointer)1)
                {
                pointer v = _readVal(i);
                _map_arc_release(k);
                _map_arc_release(v);
                }
            i = i + (u32)1;
            }
        _map_slots_free(_slots);
        _map_order_free(_order);
        }

    // <Copying>: a new Map with the same key/value pairs, in the same
    // INSERTION ORDER (allKeys yields insertion order, and set() appends in
    // call order, so the copy enumerates identically). SHALLOW — keys and
    // values are shared, each retained by the new Map.
    Map* copy(void)
        {
        Map* out = Map.withCapacity(_count);
        Array* ks = allKeys();
        for (u32 i = (u32)0; i < ks.count(); i = i + (u32)1)
            {
            Hashable* k = (Hashable*)ks.get(i);
            out.set(k, get(k));
            }
        return out;
        }
    }
