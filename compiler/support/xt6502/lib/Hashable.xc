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

// Hashable.xc — protocol for 8-bit hash codes used by Map (and any
// future hashed collection).
//
// The hash domain is u8 — 256 buckets — chosen because it pays well
// for the typical xtc dictionary size (a handful to a few dozen
// entries). The byte fits in a register, the inner probe loop is
// half the cycles of a 16-bit hash, and the resulting 256-bucket
// cap is well above realistic 6502 dictionary loads. If profiling
// ever shows tables saturating, the upgrade path is mechanical:
// widen the protocol slot to u16 and lift the cap on Map.xc.
//
// Conformance is the obvious one-liner:
//
//     class MyKey <Hashable, Comparable> {
//         ...
//         u8 hash(void) { /* return some u8 derived from self */ }
//         bool equals(Object* other) { /* ... */ }
//     }
//
// Map keys must conform to BOTH Hashable (to find a slot) and
// Comparable (to detect collisions inside that slot's probe chain).
// The two protocols are independent so a value-only collection can
// pick up Comparable alone.
//
// Quality requirements: identical inputs must produce identical
// hash codes (else the lookup misses what set() planted), but the
// distribution doesn't need to be perfect — any non-degenerate hash
// keeps probe chains short for typical loads. Foundation's
// implementations XOR-fold the underlying bytes, which is good
// enough for Number / String / Data and easy to copy for user types.
//
// Hashable also bundles `equals(Object*)` — every hashed lookup
// needs to break ties inside a probe chain via equality, and a
// hash without equality is useless on its own. The Comparable
// protocol declares the same `equals` slot, so a class can list
// both `<Comparable, Hashable>` and the single method body
// satisfies both protocol slots — no duplicate code, just two
// vtable entries pointing at the same impl. Foundation's
// Number / String / Data already do exactly this.
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

protocol Hashable
    {
    u8 hash(void);
    bool equals(Object * other);
    }
