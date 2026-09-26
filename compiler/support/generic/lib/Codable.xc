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

// Codable.xc — the protocol an object adopts to be archived by a Coder.
//
// The xc form of Foundation's NSCoding. `Object` adopts it with two empty
// methods, so every class is Codable already; a class with state worth keeping
// overrides both and hands each field to the coder under a key:
//
//     class Point
//     {
//         i32    x;
//         i32    y;
//         Point* next;
//
//         void encodeWithCoder(Coder* coder)
//         {
//             super.encodeWithCoder(coder);
//             coder.encodeI32(x, "x");
//             coder.encodeI32(y, "y");
//             coder.encodeObject(next, "next");
//         }
//
//         void initWithCoder(Coder* coder)
//         {
//             super.initWithCoder(coder);
//             x    = coder.decodeI32("x");
//             y    = coder.decodeI32("y");
//             next = (Point* ?)coder.decodeObject("next");
//         }
//     }
//
//     Data*  blob = Coder.archive(p, (u8)6);           // gzip, level 6
//     Point* back = (Point* ?)Coder.unarchive(blob);   // throws on bad input
//
// ── Two ordinary methods, not a constructor ─────────────────────────────────
//
// `initWithCoder` is NOT an `init`. The unarchiver creates the instance by
// class name, which runs the class's `init(void)` if it has one, and then calls
// `initWithCoder` on that object to fill it in. So:
//
//   * the class needs an `init(void)`, or no init at all, for the unarchiver to
//     construct it;
//   * both are plain virtual methods, and a subclass calls
//     `super.encodeWithCoder` / `super.initWithCoder` so each level of the
//     hierarchy codes its own fields, as in Objective-C;
//   * an object referred to twice is archived once, and a cycle is fine: the
//     instance is registered before its `initWithCoder` runs, so a reference
//     back to it decodes to the same object even though it is not finished.
//
// ── Why this file does not import Coder.xc ──────────────────────────────────
//
// Object.xc imports this file, and every program imports Object. `Coder*` in
// the signatures below names a class this file never defines: the language
// treats `T*` as opaque until something needs the class's layout, so the name
// alone is enough. A program that never archives compiles none of Coder and
// links none of it; one that does imports Coder.xc itself.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every target except xt6502, where Object stays as it is (no extra vtable
// slots, no size change) and importing this file is an error.

#if ARCH_6502
#error "Codable: archiving is not available on xt6502"
#endif

protocol Codable
    {
    // Write this object's state into `coder`, one keyed value at a time.
    void encodeWithCoder(Coder* coder);

    // Read it back, on an instance the unarchiver has just created with
    // `init(void)`.
    void initWithCoder(Coder* coder);
    }
