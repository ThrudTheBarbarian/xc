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

// Object.xc — universal root class.
//
// Every class without an explicit parent implicitly inherits from
// Object, so this file's defaults apply to anything you might
// hand to a Map / Set / future Foundation collection without
// extra ceremony.
//
//   `equals(Object* other)` — pointer equality. Two Object*'s
//   compare equal iff they point at the same heap block.
//
//   `hash(void)` — XOR-fold the receiver's address. Distinct
//   instances live at distinct heap addresses, so they hash
//   apart by construction.
//
// Both are dirt-cheap on 6502 (a CMP/CPX pair for equals, two ZP
// reads + one EOR for hash). Concrete classes that want value
// semantics override — Number compares by stored numeric value,
// String/Data fold over their bytes — and the override wins
// through normal protocol-vtable dispatch.
//
// Caching the hash on the instance is intentionally NOT done
// here: the pointer hash is so cheap that a 1-byte cache field
// per instance would cost more in memory across the program
// than it ever saves in cycles. Concrete classes whose hash is
// genuinely expensive (long Strings) can cache in a private
// ivar of their own without making everyone else pay.

#import "Hashable.xc"
#import "Comparable.xc"
#import "String.xc"

class Object<Hashable, Comparable>
    {
        // `self` is the receiver pointer. hash XOR-folds its low two
        // address bytes; equals is pointer identity. Written with the
        // portable `self` expression (not the old inline-6502-asm
        // `__self` read, which was a no-op on the arm64 backend and
        // left every instance hashing to 0 / comparing unequal).
        // Hash the receiver's address — distinct instances live at distinct heap
        // addresses, so they hash apart. The WIDTH is the target's: the Hashable
        // protocol is u32 on the 32-bit machines and u8 on the 6502, and this is
        // the one place in Object that cares. Everything else here is
        // width-neutral, which is why Object is shared rather than duplicated.
#if ARCH_6502
    u8 hash(void)
        {
        u16 p = (u16)self;
        return (u8)p ^ (u8)(p >> 8);
        }
#else
    u32 hash(void)
        {
        u32 p = (u32)self;
        p = p ^ (p >> 16);
        p = p * (u32)2246822519;
        p = p ^ (p >> 13);
        return p;
        }
#endif

    bool equals(Object* other)
        {
        return self == other;
        }

    // `description()` — Stdio.printf's `%@` formatter dispatches here
    // through the Hashable/Comparable vtable every Object-derived
    // class carries. Returns a String wrapping the formatted
    // representation. Default returns a placeholder `<Object>`;
    // subclasses override to provide a meaningful representation.
    // Future commits will (a) introduce a per-class name table so the
    // default reports the dynamic type and (b) walk ivars via a
    // synthesised descriptor to produce `<Blob>(42, 1000, -5)`-shape
    // output without each class having to write description() by hand.
    String* description(void)
        {
        return String.withCString("<Object>");
        }
    }
