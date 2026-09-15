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

// Heap.xc — introspection on the free-list heap allocator
// ========================================================
//
// Usage (static — no instance needed):
//   #import <Heap.xc>
//
//   u32 available = Heap.size();         // free bytes right now
//   u32 capacity  = Heap.totalSize();    // compile-time heap total
//   u16 biggest   = Heap.largest();      // biggest single free block
//
// Only meaningful under -falloc=heap (currently the default on
// xl-shadow and xe-nobank, plus xt-heap / xe-heap banked layouts).
// On bump-only targets the allocator keeps no free-list metadata,
// so `size()` and `largest()` would return misleading values.
//
// size() and totalSize() are u32 because a multi-bank heap can
// easily exceed 64 KB (e.g. 6 banks × 16 KB = 96 KB on xe-heap).
// largest() stays u16 because a single free block can never span
// bank boundaries — it's bounded by the flat region size or a
// single 16 KB bank.
//
// All counts are in bytes and INCLUDE the 4-byte per-block header
// (2-byte size + 2-byte retain count) that the allocator stores in
// front of each allocation. A `new u8[100]` therefore consumes 104
// bytes from the "size" total.

class Heap
    {
    u8 dummy;

    void init(void) : main
        {
        }

    // ── size: total free bytes across all free blocks (u32) ────
    //
    // Current availability, computed by walking the free list in
    // every reserved bank. Safe to call at any time; O(free-block
    // count) per bank.

    static u32 size(void) : main
        {
        u32 result;
        asm
        {
            JSR _heap_total_free
            ; _heap_total_free returns a 24-bit free count in A/X/Y
            ; (a banked heap can hold > 64 KB free). byte 3 is always
            ; zero - the 3-byte pointer space caps the heap at 16 MB.
            ; Store the full u32 explicitly; inline-asm does not
            ; auto-marshal a return value into the caller local slot.
            STA result
            STX result+1
            STY result+2
            LDA #$00
            STA result+3
        }
        return result;
        }

    // ── largest: biggest single free-block size (u16) ──────────
    //
    // First-fit allocation means a request for N bytes only
    // succeeds if the largest free extent is >= N+4 (payload +
    // 4-byte header). Use this when you care whether `new T[N]` will
    // actually fit, not just whether there's enough total free
    // across fragmented holes. Bounded by the flat region or a
    // single bank window (≤ 16 KB), so u16 is sufficient.

    static u16 largest(void) : main
        {
        u16 result;
        asm
            {
            JSR _heap_largest_free
            STA result
            STX result+1
            }
        return result;
        }

    // ── totalSize: compile-time heap capacity (u32 const) ──────
    //
    // Returns the sum of (heap_end - heap_low) across every bank
    // reserved by the heap layout (banked-heap targets) or the
    // flat region size (xl-shadow / xe-nobank). The codegen emits
    // `heap_total_bytes` as a linker-resolved constant so this
    // works uniformly across single-bank and multi-bank layouts.
    // u32 because a multi-bank heap can exceed 64 KB.

    static u32 totalSize(void) : main
        {
        u32 result;
        asm
        {
            ; Low half of the 32-bit capacity. The codegen emits
            ; heap_total_bytes as a 16-bit equate.
            LDA #<heap_total_bytes
            STA result
            LDA #>heap_total_bytes
            STA result+1
            ; High half lives in heap_total_bytes_b2 / _b3 equates
            ; so multi-bank layouts that stake out more than 64 KB
            ; (e.g. rambo576 with 32 banks) still report correctly.
            LDA #heap_total_bytes_b2
            STA result+2
            LDA #heap_total_bytes_b3
            STA result+3
        }
        return result;
        }
    }
