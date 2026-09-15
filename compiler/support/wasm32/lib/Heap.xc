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

// Heap.xc — wasm32 heap introspection over the REAL allocator state.
// ==================================================================
//
// The Heap resolved for the wasm32 backend (ahead of
// support/generic/lib on the include path), keyed by backend
// ARCHITECTURE like the wasm32 Stdio.xc.
//
// The wasm32 allocator is the generated in-module coalescing free-list
// (XTWasmBackend emitRuntimeInto): a bump frontier above the 1 MiB heap
// base, growing linear memory on demand, with freed blocks on an
// address-ordered coalescing list. The three externs below are emitted
// INTO the module alongside it (they read the allocator's $__heap /
// $__free state directly), so these numbers are the allocator's own —
// not layout constants.
//
// Byte accounting matches the reference Heap API: counts include each
// block's header, and totalSize() grows when the allocator grows the
// memory. See support/xt6502/lib/Heap.xc for the API prose.

// Provided by the wasm32 backend's generated runtime, not the host.
i32 _xtc_heap_free_bytes(void);
i32 _xtc_heap_total_bytes(void);
i32 _xtc_heap_largest(void);

class Heap
    {
    u8 dummy;

    void init(void)
        {
        }

    // Currently-free bytes: the untouched bump tail plus every
    // free-list block (headers included).
    static u32 size(void)
        {
        return (u32)_xtc_heap_free_bytes();
        }

    // Biggest single free extent, capped to the API's u16 range (the
    // bump tail alone is usually ~1 MiB).
    static u16 largest(void)
        {
        u32 big = (u32)_xtc_heap_largest();
        if (big > (u32)$FFFF)
            return (u16)$FFFF;
        return (u16)big;
        }

    // Current capacity: everything above the heap base. Grows when the
    // allocator grows the linear memory.
    static u32 totalSize(void)
        {
        return (u32)_xtc_heap_total_bytes();
        }
    }
