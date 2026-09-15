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

// Enumerable.xc — protocol for class-instance iteration via for-in.
//
// xtc's `for (T* x in collection)` syntax already handles
// fixed-size arrays, slices, ranges, and heap-allocated pointers
// (`u8*` etc.) — anything where the codegen can derive a count
// and an element addressing scheme up front. Class instances need
// a different machinery, since the storage layout is private. A
// class declaring conformance to Enumerable promises two methods
// the for-in codegen can call:
//
//     u16     enumLength(void);   // total element count
//     Object* enumAt(u16 i);      // element at index i (0-based)
//
// Conformance:
//
//     class MyContainer <Enumerable> {
//         ...
//         u16 enumLength(void) { return _count; }
//         Object* enumAt(u16 i) { /* return element at i */ }
//     }
//
// The for-in codegen rewrites
//
//     for (Object* e in col) { body; }
//
// into a counted loop that reads `col.enumLength()` once at
// loop entry and then calls `col.enumAt(i)` per iteration —
// stateless, so nested iteration over the same collection works,
// and `break` / `continue` follow the usual semantics. Calls go
// through the protocol's vtable slot so the loop body sees the
// concrete class's method even when `col`'s static type is
// `Object*`.
//
// Element type is `Object*`. Containers that store typed pointers
// (Number / String / Data / user classes inheriting from Object)
// expose them through this protocol; downcast inside the loop
// body if you need the concrete type:
//
//     for (Object* o in arr) {
//         Number* n = (Number* ?)o;
//         if (n != 0) Stdio.printf("%d\n", n.asI16());
//     }
//
// Primitive-element collections (String's u8 chars, Data's u8
// bytes) keep using the existing pointer-style for-in — no
// boxing through Object* needed there.
//
// ── xt6502 build of this class ───────────────────────────────────────────
// The 6502 Foundation. Counts, indices and lengths are u16 and the hash is
// u8, because on an 8-bit CPU a 32-bit index is four bytes of arithmetic on
// every compare and every increment, and a container that could address more
// than 65535 elements could not fit them anyway — one heap block is capped
// at a 12 KB bank. The 32-bit machines (arm64, arm9, m68k, x86_64) use
// `support/generic/lib/` instead, which is uncapped and hashes 32-bit.
//
// Same API, different implementation. Neither target pays for the other's
// constraints.
//
// Only the files whose WIDTHS differ live here. Everything width-neutral —
// Object, Comparable, Sort, the Foundation umbrella — exists once, in
// generic/lib, and is shared: a library file's `#import "X.xc"` resolves
// through the platform's lib dir first and generic/lib second, never against
// its own directory. So generic/lib/Object.xc picks up THIS String and THIS
// Hashable when the target is the 6502.
//

protocol Enumerable
    {
    u16 enumLength(void);
    Object* enumAt(u16 i);
    }
