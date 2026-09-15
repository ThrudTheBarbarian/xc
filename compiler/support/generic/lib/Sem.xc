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

// Sem.xc — a counting semaphore.
// ==============================
//
// private:docs/Design/threading.md §3.2. Where a Mutex says "one at a time", a Sem says
// "at most N at a time", and where a Cond needs a predicate and a lock, a Sem
// carries its own count. The two shapes it is actually reached for:
//
//   * a permit pool — `Sem* slots = Sem.withCount((i32)4);` then wait/post
//     around the limited resource;
//   * a completion latch — a worker `post()`s as it finishes and the joiner
//     `wait()`s once per worker.
//
// wait() blocks while the count is zero and decrements it otherwise; post()
// increments and wakes one waiter. Counts never go negative.

#if ARCH_6502
#error "Sem: xt6502 has no threads (private:docs/Design/threading.md §5)"
#endif
#if ARCH_m68k
#error "Sem: the Atari ST target has no threads (private:docs/Design/threading.md §5)"
#endif

pointer _xt_sem_new(i32 initial);
void _xt_sem_free(pointer s);
void _xt_sem_wait(pointer s);
i32 _xt_sem_trywait(pointer s);
void _xt_sem_post(pointer s);

class Sem
    {
    pointer _s;

    // A bare `new Sem()` starts at zero — the latch shape. Use
    // `Sem.withCount(n)` for a permit pool.
    void init(void)
        {
        _s = _xt_sem_new((i32)0);
        }

    static Sem* withCount(i32 initial)
        {
        Sem* s = new Sem();
        if (initial > (i32)0)
            {
            // init() already made a zero-count semaphore; raising it by posting
            // keeps ONE construction path in the runtime rather than two.
            for (i32 i = (i32)0; i < initial; i++)
                _xt_sem_post(s._s);
            }
        return s;
        }

    void wait(void)
        {
        _xt_sem_wait(_s);
        }
    void post(void)
        {
        _xt_sem_post(_s);
        }

    // Take a permit if one is available; never blocks.
    bool tryWait(void)
        {
        return _xt_sem_trywait(_s) != (i32)0;
        }

    void dealloc(void)
        {
        if (_s != (pointer)0)
            {
            _xt_sem_free(_s);
            _s = (pointer)0;
            }
        }
    }
