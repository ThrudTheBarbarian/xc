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

// Runtime class names: `className()` and `Object.newInstanceOfClass(name)`.
// Not on the 6502, where Object stays as it was.
//
// The compiler writes the per-class parts of this into each module that needs
// them (a library, a `-c` object, a program that imports one, or a program
// that names either method):
//
//   * `String* _xtc_cname_<C>(void)` for each class C, returning "C". On the
//     targets that link several modules its address sits in C's conformance
//     itable under the id _XTC_CLASSNAME_ID, so className() reads it from the
//     receiver's own vtable, whichever module built the class.
//   * `Object* _xtc_cnew_<hash>(String* name)`, which runs `new C()` for the
//     class with that name, then asks each imported module's own function.
//     A library or `-c` object names its function in its interface.
//   * `Object* _xtc_class_new(String* name)`, defined by the module that holds
//     `main` (or by the library), which calls that module's function. Where
//     nothing needs the table it returns null.
//   * m68k links one module, so className() there is `_xtc_class_name(o)`, a
//     chain of downcasts from the most derived class up.
#if !ARCH_6502
#define _XTC_CLASSNAME_ID 278412134
typedef String* _xtc_cname_fn(void);
Object* _xtc_class_new(String* name);
#if ARCH_m68k
String* _xtc_class_name(Object* o);
#endif

// Does the String `name` spell the C string `lit`? Used by the generated
// `_xtc_cnew_<hash>` functions.
bool _xtc_class_is(String* name, u8* lit)
    {
    u8* a = name.cString();
    i32 i = (i32)0;
    while (a[i] != (u8)0 && a[i] == lit[i])
        i = i + (i32)1;
    return a[i] == lit[i];
    }
#endif

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

#if !ARCH_6502
    // The name of the receiver's dynamic class, as written in its source:
    // "Point" for a Point held as an Object*. Null when the class was built
    // by a compiler that did not record names.
    final String* className(void)
        {
#if ARCH_m68k
        return _xtc_class_name(self);
#else
        // obj[0] is the vtable and vtable[1] its conformance itable: (id,
        // pointer) pairs ending in a zero id.
        pointer* op = (pointer*)(pointer)self;
        pointer* vp = (pointer*)op[0];
        if (vp == (pointer*)0)
            return (String*)0;
        pointer* ip = (pointer*)vp[1];
        if (ip == (pointer*)0)
            return (String*)0;
        i32 k = (i32)0;
        while (ip[k + k] != (pointer)0)
            {
            if ((u32)ip[k + k] == (u32)_XTC_CLASSNAME_ID)
                {
                _xtc_cname_fn* f = (_xtc_cname_fn*)ip[k + k + (i32)1];
                return f();
                }
            k = k + (i32)1;
            }
        return (String*)0;
#endif
        }

    // A new instance of the class called `name`, as `new C()` makes one: its
    // zero-argument init runs if it has one. Null when no class of that name
    // is in the program or in a module it imports.
    static Object* newInstanceOfClass(String* name)
        {
        if (name == (String*)0)
            return (Object*)0;
        return _xtc_class_new(name);
        }
#endif
    }
