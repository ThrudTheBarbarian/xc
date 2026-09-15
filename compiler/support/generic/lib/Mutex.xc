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

// Mutex.xc — mutual exclusion, and the scoped guard that goes with it.
// =====================================================================
//
// private:docs/Design/threading.md §3.2. A thin wrapper over the host primitive, so the
// surface is identical everywhere threads are supported.
//
//     Mutex* m = new Mutex();
//     m.lock();
//     … touch the shared state …
//     m.unlock();
//
// Or, letting scope exit do it — xtc has deterministic ARC teardown, so a local
// whose `dealloc` unlocks is the natural RAII idiom and needs no new syntax:
//
//     {
//         Guard* g = Guard.on(m);      // locks
//         … touch the shared state …
//     }                                // g dropped → unlocks, on every path
//
// The Guard form is worth preferring wherever the body can `return` early: an
// unlock skipped by an early return is a deadlock a long way from its cause.
//
// ── Ordering ────────────────────────────────────────────────────────────
// lock() carries acquire and unlock() carries release (threading.md §6), so
// everything a thread wrote before unlocking is visible to the next thread that
// locks. That single rule is what makes disciplined locking sufficient.

#if ARCH_6502
#error "Mutex: xt6502 has no threads (private:docs/Design/threading.md §5)"
#endif
#if ARCH_m68k
#error "Mutex: the Atari ST target has no threads (private:docs/Design/threading.md §5)"
#endif

pointer _xt_mutex_new(void);
void _xt_mutex_free(pointer m);
void _xt_mutex_lock(pointer m);
void _xt_mutex_unlock(pointer m);
i32 _xt_mutex_trylock(pointer m);

class Mutex
    {
    pointer _m;

    void init(void)
        {
        _m = _xt_mutex_new();
        }

    void lock(void)
        {
        _xt_mutex_lock(_m);
        }
    void unlock(void)
        {
        _xt_mutex_unlock(_m);
        }

    // True if the lock was taken; false if another thread holds it. Never
    // blocks.
    bool tryLock(void)
        {
        return _xt_mutex_trylock(_m) != (i32)0;
        }

    // The raw handle, for Cond.wait — Cond has to hand the SAME OS mutex to the
    // host primitive, and nothing else should reach for this.
    pointer handle(void)
        {
        return _m;
        }

    void dealloc(void)
        {
        if (_m != (pointer)0)
            {
            _xt_mutex_free(_m);
            _m = (pointer)0;
            }
        }
    }

    // Scope-bounded lock ownership. `Guard.on(m)` locks; dropping the guard
    // unlocks, whichever way the scope is left.
    class Guard
    {
    Mutex* _mutex;

    void init(void)
        {
        }

    static Guard* on(Mutex* m)
        {
        Guard* g = new Guard();
        g._mutex = m; // strong: the mutex must outlive the guard
        if (m != 0)
            m.lock();
        return g;
        }

    // Release early, before the guard itself goes away. Idempotent, so an
    // explicit unlock followed by scope exit does not double-unlock.
    void unlock(void)
        {
        if (_mutex != 0)
            {
            _mutex.unlock();
            _mutex = (Mutex*)0;
            }
        }

    void dealloc(void)
        {
        unlock();
        }
    }
