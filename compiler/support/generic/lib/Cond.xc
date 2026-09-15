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

// Cond.xc — a condition variable: wait until another thread says otherwise.
// =========================================================================
//
// private:docs/Design/threading.md §3.2.
//
//     Mutex* m = new Mutex();
//     Cond*  c = new Cond();
//
//     // consumer
//     m.lock();
//     while (!ready) c.wait(m);        // ALWAYS a loop, never a bare `if`
//     … consume …
//     m.unlock();
//
//     // producer
//     m.lock();
//     ready = true;
//     c.signal();
//     m.unlock();
//
// `wait` atomically releases the mutex and blocks, and re-acquires it before
// returning — so the predicate can only be tested under the lock, which is what
// closes the lost-wakeup window. The loop is load-bearing: a wait may return
// without the predicate holding (another waiter got there first, or the host
// woke it spuriously), and testing the predicate again is the only correct
// response.

#if ARCH_6502
#error "Cond: xt6502 has no threads (private:docs/Design/threading.md §5)"
#endif
#if ARCH_m68k
#error "Cond: the Atari ST target has no threads (private:docs/Design/threading.md §5)"
#endif

#import "Mutex.xc"

pointer _xt_cond_new(void);
void _xt_cond_free(pointer c);
void _xt_cond_wait(pointer c, pointer m);
void _xt_cond_signal(pointer c);
void _xt_cond_broadcast(pointer c);

class Cond
    {
    pointer _c;

    void init(void)
        {
        _c = _xt_cond_new();
        }

    // Release `m`, block until signalled, re-acquire `m`. The caller must hold
    // `m` on entry and must re-test its predicate on return.
    void wait(Mutex* m)
        {
        if (m == 0)
            return;
        _xt_cond_wait(_c, m.handle());
        }

    // Wake one waiter (if any). Cheapest when any single waiter can make
    // progress — a queue with one item, say.
    void signal(void)
        {
        _xt_cond_signal(_c);
        }

    // Wake every waiter. Needed when waiters are waiting on DIFFERENT
    // predicates over the same mutex, where signal() could wake one that cannot
    // proceed and leave one that could still asleep.
    void broadcast(void)
        {
        _xt_cond_broadcast(_c);
        }

    void dealloc(void)
        {
        if (_c != (pointer)0)
            {
            _xt_cond_free(_c);
            _c = (pointer)0;
            }
        }
    }
