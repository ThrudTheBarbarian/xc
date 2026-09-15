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

// Copying.xc — protocol for producing an independent duplicate of an object.
//
//     class MyType <Copying>
//     {
//         u32 v;
//         Object* copy(void) { MyType* c = new MyType(); c.v = v; return c; }
//     }
//
// ── Why there is no `mutableCopy` ───────────────────────────────────────────
//
// Foundation has both `copy` and `mutableCopy` because it splits types across
// class pairs: NSString/NSMutableString, NSArray/NSMutableArray. `copy` of an
// NSMutableString gives you an immutable NSString, and `mutableCopy` gives you a
// mutable one, so the two genuinely differ.
//
// xtc has no such split. There is one `String`, one `Array`, one `Map` — each
// already mutable — so `copy` and `mutableCopy` would return exactly the same
// thing. Rather than carry a synonym that only makes sense in a language we are
// not, xtc has `copy` alone. Code ported from Foundation should read both
// `-copy` and `-mutableCopy` as this one method.
//
// ── Depth ───────────────────────────────────────────────────────────────────
//
// `copy` is SHALLOW, matching Foundation: the receiver's own storage is
// duplicated, the objects it references are not. Copying an Array gives you a
// new Array whose slots point at the same elements (each retained by the new
// Array, so both copies own their references independently). If you need the
// elements duplicated too, walk the copy and replace each one — the library
// cannot know whether a deep copy is meaningful for your element type, and
// silently deep-copying a graph is a far worse default than an explicit loop.
//
// A copy is returned +1, owned by the caller, exactly like `new`.
//
// ── The return type ─────────────────────────────────────────────────────────
//
// `Object*`, not `Self*` — xtc has neither covariant returns nor generics, so
// the protocol slot has to be typed at the root. Call sites downcast:
//
//     Array* dup = (Array* ?)original.copy();
//
// which is the same shape every other type-erased return in the library takes.

// ── How a class implements it ───────────────────────────────────────────────
//
// The ordinary way, and it needs nothing from the runtime — construct a new
// instance and assign each field across:
//
//     Object* copy(void)
//     {
//         MyType* c = new MyType();
//         c.x     = x;          // scalars: plain copies
//         c.obj   = obj;        // strong ivar: ARC retains on assignment
//         c.array = array;      // shared, not duplicated — copy is SHALLOW
//         return (Object*)c;
//     }
//
// Assignment to a strong ivar emits the release-old / retain-new pair, so the
// copy owns its references independently of the original with no manual
// refcounting.
//
// There is deliberately NO automatic default on Object that copies any subclass
// it has never seen. Such a thing would need the class's strong-ivar layout —
// a raw byte copy duplicates strong references without retaining them, so the
// first dealloc over-releases and the second touches freed memory. Objective-C
// takes the same position: NSObject's -copy forwards to -copyWithZone:, which
// raises unless the class implements NSCopying. Each type says how it copies.
//
// Types owning a heap buffer — String, Array, Map, Set, Data — must implement
// this rather than lean on field assignment alone, since two live objects
// sharing one `_bytes` or `_slots` is exactly the bug to avoid.

#import "Object.xc"

protocol Copying
    {
    // The requirement is spelled `Object*`, but an implementation may declare
    // its OWN type — returns are covariant. Prefer that: `Object*` on a
    // container collides with the typed-collection erasure convention, where an
    // `Object*` return means "one of my elements", and `Array<String>.copy()`
    // was therefore typed `String*` (private:docs/bugs/051).
    Object* copy(void);
    }
