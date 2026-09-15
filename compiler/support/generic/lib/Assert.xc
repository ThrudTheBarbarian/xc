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

// Assert.xc — lightweight test-assertion helpers for xtc fixtures
// ================================================================
//
// Usage (static — no instance needed):
//   #import "Assert.xc"
//
//   void main(void)
//   {
//       Assert.isTrue(1 + 1 == 2);
//       Assert.isEqual(counter, 42);
//       Assert.isNull(nullPtr);
//       Assert.summary();
//   }
//
// Each assertion increments the internal test counter; a failing
// assertion also increments the fail counter and prints
// `FAIL T<n>` (with n the 1-based test index). `summary()` prints
// the canonical `DONE <count>` line that the run_fixtures.sh
// runner scans for, plus a `FAIL <m> tests` line if anything
// failed.
//
// ── Release-build gating ─────────────────────────────────────────
// Compiling with `-DNDEBUG` or `-DRELEASE` turns every method body
// in this class into a no-op. The call sites still compile (the
// class and its signatures remain), so you don't have to wrap
// every `Assert.*(…)` call in `#ifdef`. At -O2 and above the leaf
// inliner elides the empty-bodied calls entirely, making the
// asserts zero-cost at runtime in release builds. At O0 the call
// sites still emit a JSR through the empty stub, which is fine
// for the cases where O0 is being used anyway.

#if defined(NDEBUG) || defined(RELEASE)
#define ASSERT_DISABLED 1
#endif

#import <Stdio.xc>

class Assert
    {
    u16 count;
    u16 fails;

    void init(void)
        {
#ifndef ASSERT_DISABLED
        count = 0;
        fails = 0;
#endif
        }

    // ── Core: isTrue / isFalse ─────────────────────────────────
    // Every other assertion funnels through isTrue so the counter
    // bookkeeping and the `FAIL T<n>` print live in one place.

    static void isTrue(bool ok)
        {
#ifndef ASSERT_DISABLED
        count = count + 1;
        if (!ok)
            {
            fails = fails + 1;
            Stdio.printf("FAIL T%u\n", count);
            }
#endif
        }

    static void isFalse(bool ok)
        {
#ifndef ASSERT_DISABLED
        isTrue(!ok);
#endif
        }

    // ── isEqual — overloaded for common scalar widths ──────────

    static void isEqual(u16 a, u16 b)
        {
#ifndef ASSERT_DISABLED
        isTrue(a == b);
#endif
        }

    static void isEqual(u32 a, u32 b)
        {
#ifndef ASSERT_DISABLED
        isTrue(a == b);
#endif
        }

    static void isEqual(i16 a, i16 b)
        {
#ifndef ASSERT_DISABLED
        isTrue(a == b);
#endif
        }

    static void isEqual(i32 a, i32 b)
        {
#ifndef ASSERT_DISABLED
        isTrue(a == b);
#endif
        }

    // ── isNotEqual ─────────────────────────────────────────────

    static void isNotEqual(u16 a, u16 b)
        {
#ifndef ASSERT_DISABLED
        isTrue(a != b);
#endif
        }

    static void isNotEqual(u32 a, u32 b)
        {
#ifndef ASSERT_DISABLED
        isTrue(a != b);
#endif
        }

    // ── Null / non-null pointer checks ─────────────────────────

    static void isNull(pointer p)
        {
#ifndef ASSERT_DISABLED
        isTrue(p == (pointer)0);
#endif
        }

    static void isNotNull(pointer p)
        {
#ifndef ASSERT_DISABLED
        isTrue(p != (pointer)0);
#endif
        }

    // ── Range and ordering checks ──────────────────────────────

    static void isInRange(u16 v, u16 lo, u16 hi)
        {
#ifndef ASSERT_DISABLED
        isTrue(v >= lo && v <= hi);
#endif
        }

    static void isLess(u16 a, u16 b)
        {
#ifndef ASSERT_DISABLED
        isTrue(a < b);
#endif
        }

    static void isGreater(u16 a, u16 b)
        {
#ifndef ASSERT_DISABLED
        isTrue(a > b);
#endif
        }

    // ── Summary / reset ────────────────────────────────────────
    //
    // `summary()` is also gated — a release build prints nothing,
    // which is usually what you want (your user doesn't need to
    // see `DONE 0` at the end of their program).

    static void summary(void)
        {
#ifndef ASSERT_DISABLED
        u16 c = count;
        u16 f = fails;
        Stdio.printf("DONE %u\n", c);
        if (f != 0)
            {
            Stdio.printf("FAIL %u tests\n", f);
            }
#endif
        }

    static void reset(void)
        {
#ifndef ASSERT_DISABLED
        count = 0;
        fails = 0;
#endif
        }

    // ── Accessors ──────────────────────────────────────────────
    //
    // Accessors still return 0 in release mode — callers of
    // testCount() / failCount() should expect that and either
    // gate their own logic or trust that release binaries never
    // read these for anything visible to the user.

    static u16 testCount(void)
        {
#ifndef ASSERT_DISABLED
        return count;
#else
        return 0;
#endif
        }

    static u16 failCount(void)
        {
#ifndef ASSERT_DISABLED
        return fails;
#else
        return 0;
#endif
        }
    }
