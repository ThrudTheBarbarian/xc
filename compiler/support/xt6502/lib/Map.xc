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
// bounded only by memory — the hash is u16 — so `hash & (cap - 1)`
// is the initial probe and the cap fits in u16 with room to spare.
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
void _map_order_free(u16* buf)
    {
    asm {
#if ARCH_6502
        LDA buf
        LDX buf+1
        ORA buf+1
        BEQ .mapord_done
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
.mapord_done:
#endif
    }
    }

void _map_slots_free(pointer* buf)
    {
    asm {
#if ARCH_6502
        LDA buf
        LDX buf+1
        ORA buf+1
        BEQ .mbf_done
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
.mbf_done:
#endif
    }
    }

class Map<Enumerable>
    {
    pointer* _slots; // capacity * 2 pointer cells (key, value)
    u16 _count;      // live entries (excludes tombstones)
    u16 _capacity;   // power of 2, bounded only by memory

    // Insertion order. `_order[0.._count-1]` holds the SLOT INDEX of each live
    // entry in insertion order; iteration walks it instead of the slot table.
    // Slot order is hash order and Object's default hash is address-derived, so
    // hash-order iteration differed between runs — see the generic Map.xc and
    // private:docs/Design/self-hosting.md §5. Also makes enumAt(i) O(1) for any access
    // pattern, retiring the cursor (which only helped sequential walks and left
    // nested iteration O(n^2)). u16 here to match this build's index width.
    // Dense: remove() closes the gap, which it must, since _findSlot hands a
    // tombstoned slot to the next insert and a stale entry would alias it.
    u16* _order;

    void init(void)
        {
        _slots = (pointer*)0;
        _order = (u16*)0;
        _count = (u16)0;
        _capacity = (u16)0;
        }

    // Any mutation may move entries (a resize rehashes; a remove plants a
    // tombstone), so a slot remembered before it means nothing after. Iterating
    // a map while mutating it is already undefined; this just makes sure the
    // undefined behaviour is "wrong element", never "read outside the table".
    // Allocate the slot buffer at the given (rounded-up power-of-2,
    // ≥ 16) capacity. The caller can pre-size when the rough
    // upper bound is known to skip a future resize copy. Bare
    // `new Map()` lazily allocates on the first set().
    static Map* withCapacity(u16 cap)
        {
        Map* m = new Map();
        m._growTo(cap);
        return m;
        }

    // Round `cap` up to the next power-of-2 (≥ 16), allocate
    // the slot buffer, zero-fill it (the (pointer)0 zero-bit pattern
    // marks every slot empty). Used by withCapacity and the first
    // set() call (lazy initial allocation).
    void _growTo(u16 cap)
        {
        u16 c = (u16)16;
        while (c < cap)
            c = c * (u16)2;
        pointer* buf = new pointer[c * (u16)2];
        // new u8/pointer[N] returns zero-cleared bytes from the
        // heap allocator already; explicit zero-fill is a paranoia
        // hedge against any future allocator change.
        for (u16 i = (u16)0; i < c * (u16)2; i = i + (u16)1)
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
    //
    // Refcounts don't move during resize. Each (key, value) pointer
    // is just relocated from one buffer to the other; the receiver
    // (heap object) sees no retain/release. _map_slots_free on the
    // old buffer reclaims only the slot bytes — never the pointed-
    // to objects.
    void _resize(u16 newCap)
        {
        pointer* newBuf = new pointer[newCap * (u16)2];
        for (u16 i = (u16)0; i < newCap * (u16)2; i = i + (u16)1)
            {
            newBuf[i] = (pointer)0;
            }
        // Rehash the order array IN PLACE — see the generic Map.xc: allocating a
        // second order array while both slot buffers are live exhausted the 6502
        // harness heap at the 64->128 resize. Grown further down, after the old
        // slot buffer is freed, so the big and small allocations never overlap.
        u16* ord = _order;
        u16 newMask = newCap - (u16)1;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            u16 oldSlot = ord[i];
            pointer k = _readKey(oldSlot);
            if (k == (pointer)0 || k == (pointer)1)
                continue; // defensive
            pointer v = _readVal(oldSlot);
            // Linear-probe insert into newBuf, fully inlined.
            u8 h = ((Hashable*)(Object*)k).hash();
            u16 probe = ((u16)h) & newMask;
            for (u16 j = (u16)0; j < newCap; j = j + (u16)1)
                {
                u16 slot = (probe + j) & newMask;
                u16 base = slot * (u16)2;
                pointer keyPtr = newBuf[base];
                if (keyPtr == (pointer)0)
                    {
                    newBuf[base] = k;
                    newBuf[base + (u16)1] = v;
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
        u16* grown = new u16[newCap];
        u16* cur = _order;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
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
    pointer _readKey(u16 idx)
        {
        pointer* b = _slots;
        return b[idx * (u16)2];
        }

    pointer _readVal(u16 idx)
        {
        pointer* b = _slots;
        return b[idx * (u16)2 + (u16)1];
        }

    void _writeKey(u16 idx, pointer ptr)
        {
        pointer* b = _slots;
        b[idx * (u16)2] = ptr;
        }

    void _writeVal(u16 idx, pointer ptr)
        {
        pointer* b = _slots;
        b[idx * (u16)2 + (u16)1] = ptr;
        }

    // ── Probe ────────────────────────────────────────────────────
    // Walk the probe chain for `key`. Returns the slot index of
    // either an existing match (so callers can read or overwrite)
    // or a free slot the caller can insert into. Free means: the
    // first tombstone seen on the chain if any, else the first
    // empty slot. $FFFF means "table exhausted" (every slot is a
    // live non-match) — only happens when count == capacity, which
    // the resize path will keep us out of.
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
                // Empty — terminate.
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
        if (_capacity == (u16)0)
            _growTo((u16)16);
        // α > 0.75 trigger: 4*(count + 1) > 3*capacity.
        u16 lhs = (_count + (u16)1) * (u16)4;
        u16 rhs = _capacity * (u16)3;
        if (lhs > rhs)
            _resize(_capacity * (u16)2);
        u16 slot = _findSlot(key);
        if (slot == $FFFF)
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
            // New key goes on the end of the insertion order; _count is the next
            // free order index because _order is kept dense.
            u16* ord = _order;
            ord[_count] = slot;
            _count = _count + (u16)1;
            }
        }

    Object* get(Hashable* key)
        {
        if (_count == (u16)0)
            return (Object*)0;
        u16 slot = _findSlot(key);
        if (slot == $FFFF)
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
        if (_count == (u16)0)
            return;
        u16 slot = _findSlot(key);
        if (slot == $FFFF)
            return;
        pointer k = _readKey(slot);
        pointer kTag = k;
        if (kTag == (pointer)0 || kTag == (pointer)1)
            return; // not present
        pointer v = _readVal(slot);
        // Plant tombstone first, then drop strong refs.
        _writeKey(slot, (pointer)1);
        _writeVal(slot, (pointer)0);

        // Close the gap in _order — it must stay dense: _findSlot hands this
        // tombstoned slot to the next insert, so a stale order entry would later
        // alias a different key and iteration would yield it twice.
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
        _map_arc_release(k);
        _map_arc_release(v);
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
            pointer v = _readVal(i);
            _writeKey(i, (pointer)0);
            _writeVal(i, (pointer)0);
            _map_arc_release(k);
            _map_arc_release(v);
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

    // ── Views ────────────────────────────────────────────────────
    // `contains` asks whether the KEY is present, which is not the same
    // question as "is get(k) non-null" — a key stored with a null value is
    // still a key. It used to be written as `get(key) != 0`, which answered the
    // wrong one.
    bool containsKey(Hashable* key)
        {
        if (_count == (u16)0)
            return false;
        u16 slot = _findSlot(key);
        if (slot == $FFFF)
            return false;
        pointer k = _readKey(slot);
        return k != (pointer)0 && k != (pointer)1;
        }

    Array* allKeys(void)
        {
        // In insertion order — see _order.
        Array* out = Array.withCapacity(_count);
        u16* ord = _order;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
            {
            out.add((Object*)_readKey(ord[i]));
            }
        return out;
        }

    Array* allValues(void)
        {
        // In insertion order, matching allKeys index for index.
        Array* out = Array.withCapacity(_count);
        u16* ord = _order;
        for (u16 i = (u16)0; i < _count; i = i + (u16)1)
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
    // matching value). Walks the slot table skipping empties and
    // tombstones. enumLength == count, so the for-in driver iterates
    // exactly _count times.
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

    // ── Destruction ──────────────────────────────────────────────
    // Walk the slot table releasing every live key+value pair, then
    // free the slot buffer.
    void dealloc(void)
        {
        u16 i = (u16)0;
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
            i = i + (u16)1;
            }
        _map_slots_free(_slots);
        _map_order_free(_order);
        }
    }
