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

// ThreadLocal.xc — per-thread storage, one slot per instance.
// ===========================================================
//
// private:docs/Design/threading.md §3.3 proposed a `thread` storage qualifier on a
// global (`thread i32 gScratch;`). This is that requirement met as a library
// class instead, and the difference is worth stating plainly rather than
// leaving it to be discovered:
//
//   * a qualifier would need per-target thread-local RELOCATIONS — Mach-O
//     thread-local variables, ELF TLS models, and a TPIDRURW convention on
//     arm9 — in the in-house assembler and linker of every target;
//   * the actual requirement (per-thread scratch that a worker can stash
//     something in) is met by a key/value slot with no new code generation at
//     all.
//
// So the qualifier is NOT implemented and this is what exists. If a program
// later needs the qualifier's ergonomics badly enough to pay for the
// relocations, this class is what it would be lowered to.
//
//     ThreadLocal* scratch = new ThreadLocal();   // shared handle, per-thread value
//     …in each thread…
//     scratch.set((pointer)myBuffer);
//     pointer mine = scratch.get();               // only this thread's value
//
// The VALUE is a raw `pointer`, deliberately: a per-thread slot that held a
// class reference would need a per-thread release when the thread exits, and
// the runtime has no thread-exit hook to run one from. Store a pointer to
// something the program keeps alive itself.

#if ARCH_6502
#error "ThreadLocal: xt6502 has no threads (private:docs/Design/threading.md §5)"
#endif
#if ARCH_m68k
#error "ThreadLocal: the Atari ST target has no threads (private:docs/Design/threading.md §5)"
#endif

u32 _xt_tls_new(void);
void _xt_tls_set(u32 key, pointer v);
pointer _xt_tls_get(u32 key);

class ThreadLocal
    {
    u32 _key;

    void init(void)
        {
        _key = _xt_tls_new();
        }

    // Every thread starts with a null value in a freshly created slot.
    pointer get(void)
        {
        return _xt_tls_get(_key);
        }
    void set(pointer value)
        {
        _xt_tls_set(_key, value);
        }

    // No dealloc: keys are never destroyed. Deleting a key while another thread
    // still holds a value in it is a use-after-free waiting to happen, and a
    // program allocates a handful of these at startup — not per operation.
    }
