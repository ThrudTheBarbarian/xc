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

// xt-thread-exit.c — the per-thread teardown seam.
//
// private:docs/Design/threading.md §9.10. There are FOUR places a thread body returns —
// pthreads, Win32, arm9/XTOS, and the freestanding clone/kernel32 runtime — and
// they are all the same shape: `xt_thread_entry` calls `code(recv)` and returns.
// This is the one thing they all call on the way out, so a per-thread resource
// gets released in one place rather than four.
//
// ── Why it exists: allocators with per-thread state ──────────────────────
//
// mimalloc (`-fmalloc=mimalloc`) gives each thread its own heap, initialised
// lazily on first allocation. That half needs no help. The other half does: a
// thread that exits without `mi_thread_done()` leaves its heap behind, so a
// program that spawns and joins repeatedly — a `Pool.forRange` over a big range
// is exactly that — accretes one per worker.
//
// On a hosted target mimalloc hooks the platform's thread-destructor mechanism
// itself. The FREESTANDING x86-64 path has none to hook: threads there are a raw
// `clone`, with no pthread key and no destructor list. That is precisely the
// target `-fmalloc=mimalloc` is wired for, so the hook is not belt-and-braces.
//
// ── Why the weak reference is confined to ONE runtime ────────────────────
//
// The allocator is chosen per LINK, not per runtime source, so the runtime
// cannot know whether mimalloc is in the program. A weak undefined reference
// answers that at link time for free — but only on a linker that implements
// one. The in-house Mach-O writer does not: it emits a weak undefined as an
// ordinary import, and the program then fails to LOAD with
// "Symbol not found: _mi_thread_done". (Found the direct way.)
//
// That costs nothing, because mimalloc is wired for x86-64 only, and that path
// drives ld.lld — which does implement it. So the weak call lives in the
// freestanding runtime alone, behind XT_THREAD_EXIT_MIMALLOC, and every other
// runtime gets the seam as a no-op. When another target gains mimalloc, define
// the macro there too rather than reaching for the weak symbol globally.

#ifndef XT_THREAD_EXIT_C_INCLUDED
#define XT_THREAD_EXIT_C_INCLUDED

#ifdef XT_THREAD_EXIT_MIMALLOC
// mimalloc's public API. Weak, so a program that does not link mimalloc simply
// has a null here. Only ever compiled on a linker that implements weak
// undefined symbols — see above.
extern void mi_thread_done(void) __attribute__((weak));
#endif

// Called by every runtime's thread entry after the body returns, and ONLY from
// there — a thread that leaves any other way (a fault, or `exit` from a worker)
// is ending the whole process, at which point per-thread reclaim is moot.
void _xt_thread_exiting(void)
    {
#ifdef XT_THREAD_EXIT_MIMALLOC
    if (mi_thread_done)
        mi_thread_done();
#endif
    }

#endif // XT_THREAD_EXIT_C_INCLUDED
