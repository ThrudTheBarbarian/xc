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

// Atomic.xc — one i32 that several threads may touch without a lock.
// ==================================================================
//
// private:docs/Design/threading.md §3.2/§6. Every operation here is sequentially
// consistent, which is stronger than the acquire/release model the design
// promises — so a program written against the documented model is correct on
// this implementation, and a future relaxation cannot break it.
//
//     Atomic* counter = new Atomic();
//     …in each thread…  counter.add((i32)1);
//     …after joining…   counter.load()
//
// ── What this is NOT ────────────────────────────────────────────────────
// It is not the ARC refcount. Objects are made thread-safe by the compiler
// (-fthread-safe-arc, auto-enabled when a program spawns a thread), which emits
// the ISA's atomic read-modify-write inline; this class is for the program's
// own counters and flags.
//
// ── Cost ────────────────────────────────────────────────────────────────
// Each operation is a call into the runtime, not an inlined instruction. That
// is a deliberate v1 trade: one implementation, identical semantics on every
// host, no per-backend lowering to get wrong. It is the wrong tool for a hot
// inner loop — accumulate in a local and fold once at the end.

#if ARCH_6502
#error "Atomic: xt6502 has no threads (private:docs/Design/threading.md §5)"
#endif
#if ARCH_m68k
#error "Atomic: the Atari ST target has no threads (private:docs/Design/threading.md §5)"
#endif

i32 _xt_atomic_load_i32(pointer slot);
void _xt_atomic_store_i32(pointer slot, i32 v);
i32 _xt_atomic_add_i32(pointer slot, i32 delta);
i32 _xt_atomic_xchg_i32(pointer slot, i32 v);
i32 _xt_atomic_cas_i32(pointer slot, i32 expected, i32 desired);

class Atomic
    {
    // The value lives in a one-element heap array rather than an ivar so its
    // address is a plain `pointer` the runtime can operate on. (Taking the
    // address of an ivar would work too, but this keeps the slot's alignment
    // and lifetime the allocator's business.)
    i32* _slot;

    void init(void)
        {
        _slot = new i32[1];
        _slot[0] = (i32)0;
        }

    static Atomic* withValue(i32 v)
        {
        Atomic* a = new Atomic();
        a.store(v);
        return a;
        }

    i32 load(void)
        {
        return _xt_atomic_load_i32((pointer)_slot);
        }
    void store(i32 v)
        {
        _xt_atomic_store_i32((pointer)_slot, v);
        }

    // Returns the value AFTER the operation, so `add(1)` reads like `++x` under
    // a lock — the count a caller wants is the one it just produced.
    i32 add(i32 delta)
        {
        return _xt_atomic_add_i32((pointer)_slot, delta);
        }
    i32 increment(void)
        {
        return _xt_atomic_add_i32((pointer)_slot, (i32)1);
        }
    i32 decrement(void)
        {
        return _xt_atomic_add_i32((pointer)_slot, (i32)-1);
        }

    // Set to `v`, returning the value that was there.
    i32 exchange(i32 v)
        {
        return _xt_atomic_xchg_i32((pointer)_slot, v);
        }

    // Compare-and-swap: store `desired` and return true only if the slot held
    // `expected`. Strong — a false return means the value really had changed,
    // so a retry loop spins only on genuine contention.
    bool compareAndSwap(i32 expected, i32 desired)
        {
        return _xt_atomic_cas_i32((pointer)_slot, expected, desired) != (i32)0;
        }

    void dealloc(void)
        {
        if (_slot != 0)
            {
            delete _slot;
            _slot = (i32*)0;
            }
        }
    }
