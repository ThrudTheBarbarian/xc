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

// Comparable.xc — protocol for value equality, and optionally value ORDERING,
// across heterogeneous `Object*` references.
//
// xtc's Foundation classes (Number, String, Data) and any user class that holds
// value-like data should conform, so they can sit in collections (Array, Map,
// Set) that compare elements by value rather than by pointer identity.
//
// Conformance:
//
//     class MyType <Comparable> {
//         ...
//         bool equals(Object* other) {
//             MyType* o = (MyType* ?)other;     // safe-checked cast
//             if (o == 0) return false;
//             return /* compare self vs o by value */;
//         }
//
//         i8 compare(Object* other) {           // OPTIONAL — see below
//             MyType* o = (MyType* ?)other;
//             if (o == 0) return (i8)0;
//             if (self.v < o.v) return (i8)-1;
//             if (self.v > o.v) return (i8)1;
//             return (i8)0;
//         }
//     }
//
// `equals(Object*)` is the one requirement. A class may also expose a same-kind
// `equals(MyType*)` overload as a fast path — the overload resolver picks the
// typed one when the argument's static type is known, and falls through to the
// Object* version via the protocol's vtable slot otherwise.
//
// ── compare() — ordering, and why it is optional ────────────────────────────
//
// `compare` returns the C / Foundation convention, the same one
// NSComparisonResult uses:
//
//     < 0   self sorts BEFORE other      (NSOrderedAscending)
//       0   they sort equally            (NSOrderedSame)
//     > 0   self sorts AFTER other       (NSOrderedDescending)
//
// It is `optional` because not every value has a sensible order. Equality is
// universal; ordering is not — a colour or a network packet can be compared for
// sameness without any of them being "less than" another. A conforming class
// that omits it simply has no order, and the language says so honestly: an
// unimplemented optional method leaves a NULL vtable slot, so
//
//     cmp1_t^ f = &obj.compare;      // null when the class doesn't implement it
//     if (f) { ... }                 // this IS respondsTo
//
// Array.sort() uses exactly that test, and RETURNS FALSE rather than inventing
// an order for elements that don't define one. If you want to sort things that
// aren't Comparable-ordered, hand sortUsing() a comparator and say what the
// order is.
//
// Number, String and Data all implement compare.

// A bound comparison against one other object — the shape of `&obj.compare`.
typedef i8 cmp1_t(Object*);

protocol Comparable
    {
    bool equals(Object * other);
    optional i8 compare(Object * other);
    }
