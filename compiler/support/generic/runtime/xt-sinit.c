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

// xt-sinit.c — the race-free static-init once, for every target that threads.
//
// private:docs/Design/threading.md §4.3 / §9.5. Emitted by IR lowering ONLY for a module
// that can spawn a thread, so a single-threaded program never calls these and
// its instruction stream is unchanged.
//
// ONE source, several runtimes — the same rule as xt-threads.c, and for the same
// reason: a primitive present in only some of them fails to link in exactly the
// others. It is written entirely over the existing `_xt_*` contract
// (`_xt_rt_lock`, `_xt_thread_self_id`, `_xt_thread_yield`), so it needs nothing
// new from any target and every runtime can just include it.
//
// ── The flag ─────────────────────────────────────────────────────────────
//
//   0  untouched
//   1  an init is IN FLIGHT
//   2  complete
//
// Lowering's fast path is `if (*flag != 2)`, which is the same load / compare /
// branch the single-threaded lowering emits against 0 — the once costs nothing
// on the overwhelmingly common already-initialised path.
//
// ── One entry point, because the OPTIMISER reads the shape ───────────────
//
// This was originally two calls — `_xtc_sinit_enter` returning "must I run it?",
// then the initialiser, then `_xtc_sinit_done`. That needs a branch between
// them, so the guard's slow path was TWO basic blocks, and
// XTIROptStaticInitGuard (which hoists a guard out of a loop and folds away
// dominated duplicates) requires a SINGLE block ending in a Branch. Threaded
// programs therefore silently lost the optimisation.
//
// Passing the initialiser in collapses it back to one block — one call, then
// Branch — which is the shape the pass already understands. The cost is an
// indirect call to `init` instead of a direct one, once per class per program.
//
// ── Why an owner, and not just a CAS ─────────────────────────────────────
//
// A bare compare-and-swap fixes only half the bug. It stops two threads both
// RUNNING the initialiser, but the loser then sails past a flag that says "in
// flight" and reads statics the winner is still writing. So a loser has to WAIT
// for state 2.
//
// Which immediately creates the opposite hazard: a class whose `init` touches
// its own statics re-enters this function on the SAME thread, and waiting there
// would deadlock against itself. That is not hypothetical — it is a documented,
// tested behaviour (`tests/fixtures/static_init_once.xc`): a re-entrant read
// sees ZERO-INITIALISED state and does not re-run. So the answer to "must I
// wait?" is "yes, unless this init is already mine", and that needs an owner.
//
// The in-flight set is tiny — it holds one entry per initialiser currently
// running, so its depth is the mutual-dependency chain between classes, not the
// number of classes. A linear scan is the right shape at that size.

#ifndef XT_SINIT_C_INCLUDED
#define XT_SINIT_C_INCLUDED

#include <stdint.h>

// From the threading runtime that includes this file.
void _xt_rt_lock(void);
void _xt_rt_unlock(void);
uint32_t _xt_thread_self_id(void);
void _xt_thread_yield(void);

#define XT_SINIT_MAX 32

// Two parallel arrays rather than an array of {flag, owner} structs. The struct
// is 16 bytes once padded, so removing an entry compiles to a 16-byte copy —
// which clang vectorises into `ldr q0, [x10, x9, lsl #4]`, an encoding the
// in-house arm64 assembler does not implement. Parallel arrays copy two scalars
// instead, and the code reads no worse.
static uint8_t* xt_sinit_flag[XT_SINIT_MAX];
static uint32_t xt_sinit_owner[XT_SINIT_MAX];
static int xt_sinit_n;

// Run this class's initialiser exactly once, and do not return until it HAS
// been run — by us or by whoever got there first.
//
// `init` is the class initialiser and `sdata` its static block; lowering passes
// both because the decision and the call have to be one basic block (see above).
// A null `init` is accepted and simply marks the class done, which keeps the
// contract total rather than relying on lowering never to do it.
void _xtc_sinit_run(uint8_t* flag, void (*init)(void*), void* sdata)
    {
    if (!flag)
        return;
    for (;;)
        {
        _xt_rt_lock();
        uint8_t st = *flag;
        // someone finished it
        if (st == 2)
            {
            _xt_rt_unlock();
            return;
            }
        // we claim it
        if (st == 0)
            {
            *flag = 1;
            if (xt_sinit_n < XT_SINIT_MAX)
                {
                xt_sinit_flag[xt_sinit_n] = flag;
                xt_sinit_owner[xt_sinit_n] = _xt_thread_self_id();
                xt_sinit_n++;
                }
            // A full table costs only the ability to RECOGNISE a re-entrant
            // call, which would then wait. Running the init is always safe, so
            // claiming anyway beats refusing to initialise.
            _xt_rt_unlock();
            break;
            }
        // st == 1: in flight. Ours?
        uint32_t me = _xt_thread_self_id();
        int mine = 0;
        for (int i = 0; i < xt_sinit_n; i++)
            if (xt_sinit_flag[i] == flag && xt_sinit_owner[i] == me)
                {
                mine = 1;
                break;
                }
        _xt_rt_unlock();
        if (mine)
            return;         // re-entrant: caller reads zeroed statics, as documented
        _xt_thread_yield(); // another thread owns it: wait for 2
        }

    if (init)
        init(sdata);

    // Publish AFTER the body, so a waiter resumes only once the statics are
    // actually written.
    _xt_rt_lock();
    *flag = 2;
    for (int i = 0; i < xt_sinit_n; i++)
        if (xt_sinit_flag[i] == flag)
            {
            xt_sinit_n--;
            xt_sinit_flag[i] = xt_sinit_flag[xt_sinit_n];
            xt_sinit_owner[i] = xt_sinit_owner[xt_sinit_n];
            break;
            }
    _xt_rt_unlock();
    }

#endif // XT_SINIT_C_INCLUDED
