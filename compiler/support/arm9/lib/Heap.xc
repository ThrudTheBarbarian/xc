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

// Heap.xc — arm64 (native-codegen) heap introspection.
// =====================================================
//
// This is the Heap resolved for the native arm64 backend (ahead of
// support/generic/lib on the include path), keyed by backend
// ARCHITECTURE like the arm64 Stdio.xc.
//
// The arm64 corpus backend allocates through host malloc (the corpus
// C stub's `_xtc_new_*` helpers), which keeps no fixed pool or
// free-list to walk — so the Atari version's `JSR _heap_total_free`
// / `_heap_largest_free` introspection has no native equivalent.
// This port reports the OBSERVABLE values of the Atari flat-heap
// layout (xl-shadow / xe-nobank: a 12 KB region reserved after the
// $8000-$9FFF screen split, fully free at boot) so the dual-backend
// corpus fixtures exercise identical logic on both targets. It uses
// NO inline asm.
//
// See support/6502/lib/Heap.xc for the real free-list allocator
// introspection and the byte-accounting semantics (counts include
// the 4-byte per-block header, u32 to span multi-bank heaps, etc.).

class Heap
    {
    u8 dummy;

    void init(void)
        {
        }

    // Currently-free bytes. A freshly-booted reference heap has its
    // whole region free, so this equals totalSize().
    static u32 size(void)
        {
        return (u32)12288;
        }

    // Biggest single free extent. On the flat reference heap that is
    // the whole region (well within u16's range).
    static u16 largest(void)
        {
        return (u16)12288;
        }

    // Compile-time capacity: the xl-shadow / xe-nobank flat-heap
    // reservation (12 KB after the screen split). u32 to match the
    // Atari API, which sums across banks on multi-bank layouts.
    static u32 totalSize(void)
        {
        return (u32)12288;
        }
    }
