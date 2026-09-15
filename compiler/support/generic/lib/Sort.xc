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

// Sort.xc — in-place quicksort with a user-supplied comparator
// =============================================================
//
// Usage:
//   #import "Sort.xc"
//
//   i16 ascending(u16 a, u16 b) {
//       if (a < b) { return (i16)-1; }
//       if (a > b) { return (i16)1; }
//       return (i16)0;
//   }
//
//   void main(void) {
//       u16 arr[8];             // a global array works too — see "Caveats"
//       // ... fill arr ...
//       Sort.qsort(arr, (u16)8, &ascending);
//   }
//
// The comparator returns negative / zero / positive in the usual
// C qsort convention: negative if a < b, zero if a == b, positive
// if a > b. It must return i16 (not i8) — see "Why i16" below.
//
// ── Implementation ───────────────────────────────────────────────
// Recursive Lomuto-partition quicksort with the pivot at `hi`.
//
// ── Caveats ──────────────────────────────────────────────────────
// HISTORICAL, and no longer reproducing: `base` used to have to be a LOCAL
// array, because a global array name decayed to a pointer with a corrupted high
// byte and `Sort.qsort(globalArr, …)` then silently read wrong memory.
//
// Re-verified 2026-07-24 with a global `u16 g[8]`: sorts correctly on arm64 at
// -O0/-O1/-O3 and on xt6502 at -O0 and -O3. Whichever fix landed in the
// meantime was not recorded here. Left as a note rather than deleted, in case
// the underlying decay bug resurfaces in a shape this once described — if you
// hit it, this is the symptom to look for.
//
// ── Why i16 and not i8 ──────────────────────────────────────────
// The comparator returns i16 (not i8) for the same reason C's
// qsort uses `int`: the codegen currently treats i8 call results
// as unsigned when they're consumed directly by a relational
// operator (`cmp(x,y) < 0`), so a wider return type sidesteps that.
// Routing the result through a named local before the test applies
// here too.
//
// ── Static-frame eligibility ─────────────────────────────────────
// `_xtc_qsortRec` is recursive, so stage-4c marks it ineligible
// and it uses the xtc stack for its frame. Non-recursive comparator
// functions whose only &-uses are fn-ptr arguments at Sort.qsort
// call sites stay static-frame eligible under stage-2 CFA.

typedef i16 cmpU16_t(u16, u16);

// ── Free-function driver (not part of the public API) ──────────
// Implemented as a free function rather than a class method: the
// banked-target parameter window lives in ZP slots $95..$98 for
// class-method dispatch, and a comparator invoked indirectly via
// a fn-pointer argument lands on those same slots for its own
// params. Routing through a plain free function pushes qsortRec's
// `cmp` slot elsewhere and keeps them from colliding.

void _xtc_qsortRec(u16* base, u16 lo, u16 hi, cmpU16_t* cmp)
    {
    if (lo >= hi)
        {
        return;
        }

    u16 pivot = base[hi];
    u16 i = lo;
    for (u16 j = lo; j < hi; j = j + (u16)1)
        {
        i16 c = cmp(base[j], pivot);
        if (c <= (i16)0)
            {
            u16 t = base[i];
            base[i] = base[j];
            base[j] = t;
            i = i + (u16)1;
            }
        }
    u16 t = base[i];
    base[i] = base[hi];
    base[hi] = t;

    if (i > lo)
        {
        _xtc_qsortRec(base, lo, i - (u16)1, cmp);
        }
    _xtc_qsortRec(base, i + (u16)1, hi, cmp);
    }

class Sort
    {
    u8 dummy;

    void init(void)
        {
        }

    static void qsort(u16* base, u16 n, cmpU16_t* cmp)
        {
        if (n < (u16)2)
            {
            return;
            }
        _xtc_qsortRec(base, (u16)0, n - (u16)1, cmp);
        }
    }
