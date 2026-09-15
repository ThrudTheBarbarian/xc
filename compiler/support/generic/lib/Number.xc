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

// Number.xc — Object-style wrapper for any sized integer or float.
// =================================================================
//
// First step toward heterogeneous collections (Foundation-style
// Array / Dictionary / Set holding mixed primitive values). Number
// wraps a single primitive: any of xtc's sized integers (i8 / u8 /
// i16 / u16 / i32 / u32) OR a 5-byte float. Two storage kinds —
// integer (held bit-preserving as i32) and float — drive what the
// `is*` predicates report and which getters are meaningful.
//
// Usage:
//   Number* n = Number.withI16(-42);
//   if (n.isInt())   Stdio.printf("%d\n", n.asI16());
//   if (n.isFloat()) Stdio.printf("%g\n", n.asFloat());
//
// Notes:
//   * Cross-kind conversion is lazy and cached. Each Number tracks a
//     two-bit `_valid` bitmap (bit 0 = `_i` is current, bit 1 = `_f`
//     is current). `setXxx` writes the canonical slot and clears the
//     other bit. `asFloat()` on an Int Number — or `asI32()` on a
//     Float Number — converts on first call (`(float)_i` /
//     `(i32)_f` via the language-level cast machinery), stores the
//     result in the inactive slot, and lights its valid bit so
//     subsequent calls hit the cache. Narrower getters (`asI8`,
//     `asU16`, …) all derive from `_i`, so the int slot is faulted
//     in at most once regardless of how many narrow asXxx queries
//     follow.
//
//   * Same-kind narrowing / widening between int sizes is fine:
//     setI8(-5).asI16() returns -5 (sign-extended), setU16(1000).
//     asU32() returns 1000.
//
//   * setU32(0xFFFFFFFF).asI32() returns -1 (bit-preserving cast),
//     setI32(-1).asU32() returns 0xFFFFFFFF — same convention as
//     plain (i32)/(u32) casts at the language level. Bit-preserving
//     also means `withU32(0xFFFFFFFF).asFloat()` faults in via
//     `(float)_i` → -1.0 (the i32 view of the bit pattern), not
//     4294967295.0; pin the kind explicitly with `withFloat` if you
//     need the unsigned magnitude.

// Number implicitly inherits from the runtime's built-in `Object`
// root class — every parentless `class X` does — so a Number*
// fits anywhere an Object* is expected (Foundation Array slots,
// future Dictionary values, etc.) without an explicit `: Object`.
// Conforms to Comparable so heterogeneous collection helpers can
// compare numbers through the protocol's vtable.

#import "String.xc"
#import "Comparable.xc"
#import "Hashable.xc"

class Number<Comparable, Hashable>
    {
    u8 _kind;  // 0 = Int, 1 = Float — canonical kind, set by setXxx
    u8 _valid; // bit 0 = _i current, bit 1 = _f current. Bit per
               // slot rather than per asXxx variant — i8 / u8 /
               // i16 / u16 / u32 / i64 / u64 all derive from _i, so a
               // single fault-in covers every narrow getter.
    //
    // The two slots are the WIDEST of their kind, and every other accessor is
    // a cast away from one of them. Widening them is what let `Array<i64>` and
    // `Array<double>` work at all: the boxes are how a typed collection stores
    // a primitive, so a slot that could not hold an i64 meant the element type
    // could not either (private:docs/bugs/039). It is also SMALLER than keeping a
    // float beside a double would have been, and it improves the cross-kind
    // paths — an int now promotes to double (exact to 2^53) where it used to
    // promote to float (exact to 2^24).
    i64 _i;    // bit-preserving integer storage (any sized int)
    double _f; // IEEE-754 binary64 storage (any float or double)

    void init(void)
        {
        _kind = (u8)0;
        _valid = (u8)$01; // _i is current (initialised to 0)
        _i = (i64)0;
        _f = 0.0d;
        }

    // ── Factories ────────────────────────────────────────────────
    // Two flavours, same engine:
    //
    //   * `with(v)` — overloaded; the compiler picks the storage
    //     kind from `v`'s type. Use this when the literal's natural
    //     type is what you want (`Number.with(50000)` → u16).
    //
    //   * `withI8` / `withU8` / … / `withFloat` — explicit; pins
    //     the storage kind regardless of the argument's natural
    //     type. Use this when you need a wider or differently
    //     signed slot than the natural fit (`Number.withI32(42)`
    //     stores 42 in the 32-bit signed slot rather than u8).
    static Number* with(i8 v)
        {
        return Number.withI8(v);
        }
    static Number* with(u8 v)
        {
        return Number.withU8(v);
        }
    static Number* with(i16 v)
        {
        return Number.withI16(v);
        }
    static Number* with(u16 v)
        {
        return Number.withU16(v);
        }
    static Number* with(i32 v)
        {
        return Number.withI32(v);
        }
    static Number* with(u32 v)
        {
        return Number.withU32(v);
        }
    static Number* with(i64 v)
        {
        return Number.withI64(v);
        }
    static Number* with(u64 v)
        {
        return Number.withU64(v);
        }
    static Number* with(float v)
        {
        return Number.withFloat(v);
        }
    static Number* with(double v)
        {
        return Number.withDouble(v);
        }

    static Number* withI8(i8 v)
        {
        Number* n = new Number();
        n.setI8(v);
        return n;
        }
    static Number* withU8(u8 v)
        {
        Number* n = new Number();
        n.setU8(v);
        return n;
        }
    static Number* withI16(i16 v)
        {
        Number* n = new Number();
        n.setI16(v);
        return n;
        }
    static Number* withU16(u16 v)
        {
        Number* n = new Number();
        n.setU16(v);
        return n;
        }
    static Number* withI32(i32 v)
        {
        Number* n = new Number();
        n.setI32(v);
        return n;
        }
    static Number* withU32(u32 v)
        {
        Number* n = new Number();
        n.setU32(v);
        return n;
        }
    static Number* withI64(i64 v)
        {
        Number* n = new Number();
        n.setI64(v);
        return n;
        }
    static Number* withU64(u64 v)
        {
        Number* n = new Number();
        n.setU64(v);
        return n;
        }
    static Number* withFloat(float v)
        {
        Number* n = new Number();
        n.setFloat(v);
        return n;
        }
    static Number* withDouble(double v)
        {
        Number* n = new Number();
        n.setDouble(v);
        return n;
        }

    // ── Setters ──────────────────────────────────────────────────
    // Mirror of the factories: `set(v)` overloads dispatch on v's
    // type; `setI8` / `setU8` / … pin the storage kind explicitly.
    void set(i8 v)
        {
        setI8(v);
        }
    void set(u8 v)
        {
        setU8(v);
        }
    void set(i16 v)
        {
        setI16(v);
        }
    void set(u16 v)
        {
        setU16(v);
        }
    void set(i32 v)
        {
        setI32(v);
        }
    void set(u32 v)
        {
        setU32(v);
        }
    void set(i64 v)
        {
        setI64(v);
        }
    void set(u64 v)
        {
        setU64(v);
        }
    void set(float v)
        {
        setFloat(v);
        }
    void set(double v)
        {
        setDouble(v);
        }

    // Each setter pins the canonical kind, writes the canonical slot,
    // and stamps `_valid` to the single-bit "only this slot is
    // current" pattern. The inactive slot's bit is cleared so the
    // next cross-kind asXxx faults in fresh rather than serving a
    // stale cached conversion from a previous value.
    void setI8(i8 v)
        {
        _kind = (u8)0;
        _valid = (u8)$01;
        _i = (i64)v;
        }
    void setU8(u8 v)
        {
        _kind = (u8)0;
        _valid = (u8)$01;
        _i = (i64)v;
        }
    void setI16(i16 v)
        {
        _kind = (u8)0;
        _valid = (u8)$01;
        _i = (i64)v;
        }
    void setU16(u16 v)
        {
        _kind = (u8)0;
        _valid = (u8)$01;
        _i = (i64)v;
        }
    void setI32(i32 v)
        {
        _kind = (u8)0;
        _valid = (u8)$01;
        _i = (i64)v;
        }
    void setU32(u32 v)
        {
        _kind = (u8)0;
        _valid = (u8)$01;
        _i = (i64)v;
        }
    void setI64(i64 v)
        {
        _kind = (u8)0;
        _valid = (u8)$01;
        _i = v;
        }
    void setU64(u64 v)
        {
        _kind = (u8)0;
        _valid = (u8)$01;
        _i = (i64)v;
        }
    void setFloat(float v)
        {
        _kind = (u8)1;
        _valid = (u8)$02;
        _f = (double)v;
        }
    void setDouble(double v)
        {
        _kind = (u8)1;
        _valid = (u8)$02;
        _f = v;
        }

    // ── Getters ──────────────────────────────────────────────────
    // Two flavours: explicit `asXxx()` for a pinned return type
    // (`asI16()`, `asFloat()` etc.), plus return-type-overloaded
    // `value()` that picks its kind from the expected-type context
    // (assignment LHS, variable declaration, function-call
    // argument). The sema tiebreaker ranks `value()` candidates by
    // which return type matches the destination — same machinery
    // Math.rand() uses to pick `i16` vs `float` from context.
    //
    // asI32 and asFloat are the cache-aware fault-in points. Every
    // other asXxx delegates through them: narrow integer getters go
    // via asI32 + a bit-preserving cast (matching the language-
    // level `(i8)i32val` convention); the narrow `value()`
    // overloads do the same. The cache state is observable only
    // through performance — semantics match a freshly-converted
    // result every time.
    i8 value(void)
        {
        return (i8)asI32();
        }
    u8 value(void)
        {
        return (u8)asI32();
        }
    i16 value(void)
        {
        return (i16)asI32();
        }
    u16 value(void)
        {
        return (u16)asI32();
        }
    i32 value(void)
        {
        return asI32();
        }
    u32 value(void)
        {
        return (u32)asI32();
        }
    i64 value(void)
        {
        return asI64();
        }
    u64 value(void)
        {
        return asU64();
        }
    float value(void)
        {
        return asFloat();
        }
    double value(void)
        {
        return asDouble();
        }

    i8 asI8(void)
        {
        return (i8)asI32();
        }
    u8 asU8(void)
        {
        return (u8)asI32();
        }
    i16 asI16(void)
        {
        return (i16)asI32();
        }
    u16 asU16(void)
        {
        return (u16)asI32();
        }
    i32 asI32(void)
        {
        return (i32)asI64();
        }
    u32 asU32(void)
        {
        return (u32)asI64();
        }
    u64 asU64(void)
        {
        return (u64)asI64();
        }
    float asFloat(void)
        {
        return (float)asDouble();
        }

    // The two cache-aware fault-in points. Both check the valid bit
    // for their slot first; on miss they convert from the other
    // slot, populate their own slot, and OR in the valid bit so
    // subsequent calls hit the fast path. setXxx flips _valid so a
    // stale conversion can't survive across reassignment.
    i64 asI64(void)
        {
        if ((_valid & (u8)$01) == (u8)0)
            {
            // _i is stale — the canonical slot must be _f. Convert
            // via the language-level (i64)double cast: truncate
            // toward zero, saturate to 0 on overflow.
            _i = (i64)_f;
            _valid = _valid | (u8)$01;
            }
        return _i;
        }

    double asDouble(void)
        {
        if ((_valid & (u8)$02) == (u8)0)
            {
            // _f is stale — convert from _i. (double)i64 always
            // succeeds; precision falls off past 2^53, where
            // double's 53-bit mantissa runs out.
            _f = (double)_i;
            _valid = _valid | (u8)$02;
            }
        return _f;
        }

    // ── Predicates ───────────────────────────────────────────────
    bool isFloat(void)
        {
        return _kind == (u8)1;
        }
    bool isInt(void)
        {
        return _kind == (u8)0;
        }

    // ── Text ─────────────────────────────────────────────────────
    // Object's description slot — what `%@` dispatches to, and what you want
    // when a Number has to reach a label. An Int renders exactly; a Float
    // renders to six decimal places (String.withFloat's default, matching
    // C's printf %f and Stdio.printf).
    String* description(void)
        {
        if (isInt())
            return String.withI64(asI64());
        return String.withFloat(asFloat());
        }

    // ── Equality ─────────────────────────────────────────────────
    // Two overloads. The typed `equals(Number*)` is the fast path
    // when the caller has a Number-typed reference; the
    // `equals(Object*)` is the Comparable-protocol slot used by
    // heterogeneous collection helpers.
    //
    // Cross-kind comparison promotes both sides to float and
    // compares there: `Number.withI16(42).equals(Number.withFloat(
    // 42.0))` is true, and a non-integer float never compares
    // equal to any integer Number. Same-kind comparison stays
    // bit-exact (an Int / Int compare doesn't lose precision via
    // the float promotion path), so `withU32(0xFFFFFFFF)` round-
    // trips through `equals(other)` exactly when `other` is also
    // Int.
    bool equals(Number* other)
        {
        if (_kind == other._kind)
            {
            if (_kind == (u8)0)
                return _i == other._i;
            return _f == other._f;
            }
        // Cross-kind: float promotion. asFloat() faults in the
        // cached conversion if needed, so a hot Int Number being
        // compared against many Float Numbers only pays the
        // (float)i32 cost once.
        return asDouble() == other.asDouble();
        }

    bool equals(Object* other)
        {
        Number* o = (Number* ?)other;
        if (o == 0)
            return false;
        return equals(o);
        }

    // ── Ordering ─────────────────────────────────────────────────
    // Comparable's optional `compare` slot: < 0 if self sorts first, 0 if the
    // two sort equally, > 0 if self sorts after — the C / NSComparisonResult
    // convention.
    //
    // The kind rules match equals() exactly, which is what keeps the two
    // consistent: same-kind compares stay in that kind (an Int/Int compare is
    // bit-exact and never loses precision through a float promotion), and a
    // cross-kind compare promotes both sides to float, so Int(42) and
    // Float(42.0) compare EQUAL here just as they do under equals().
    //
    // Comparing against a non-Number returns 0 — "these sort equally" — because
    // there is no meaningful order between a Number and something that isn't
    // one. A sort of a mixed array is therefore stable-ish rather than wrong,
    // and the caller who wanted a defined order across kinds should have passed
    // sortUsing() a comparator that says what it is.
    i8 compare(Number* other)
        {
        if (_kind == other._kind)
            {
            if (_kind == (u8)0)
                {
                if (_i < other._i)
                    return (i8)-1;
                if (_i > other._i)
                    return (i8)1;
                return (i8)0;
                }
            if (_f < other._f)
                return (i8)-1;
            if (_f > other._f)
                return (i8)1;
            return (i8)0;
            }
        double a = asDouble();
        double b = other.asDouble();
        if (a < b)
            return (i8)-1;
        if (a > b)
            return (i8)1;
        return (i8)0;
        }

    i8 compare(Object* other)
        {
        Number* o = (Number* ?)other;
        if (o == 0)
            return (i8)0;
        return compare(o);
        }

    // ── Hash ─────────────────────────────────────────────────────
    // Hashable contract: equal keys must hash to the same byte.
    // Number's cross-kind equals promotes both sides to float, so
    // Int(42) and Float(42.0) compare equal — they must also hash
    // identically. asI32() truncates either form to the integer
    // representation: Int(42).asI32() == 42, Float(42.0).asI32() ==
    // 42, so the XOR-fold below gives the same byte. Float(42.5)
    // also asI32()'s to 42 — collides with Int(42) under this hash
    // but probe-chain equality keeps lookups correct.
    u32 hash(void)
        {
        // The value already carries 32 bits; scramble them rather than
        // folding them away into a byte.
        u32 v = (u32)asI32();
        v = v ^ (v >> 16);
        v = v * (u32)2246822519;
        v = v ^ (v >> 13);
        return v;
        }
    }
