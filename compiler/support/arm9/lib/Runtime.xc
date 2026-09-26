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

// Runtime.xc — the ARC and heap runtime the generated code calls, in xtc.
// =========================================================================
//
// The driver synthesises this as C and hands it to gcc. That is fine on a
// development host and impossible on the device, so here it is in the language
// itself: `#import "Runtime.xc"` and a program that uses classes can be built
// by the ported toolchain alone (`selfhost/tools/a9-pure.sh`).
//
// The object header is the one every backend's inline refcount sequence
// already reads, so nothing in the code generator changes to use this:
//
//   base+0   cookie 'BOTX'      base+12  dealloc function pointer
//   base+4   stride             base+16  weak chain head
//   base+8   count              base+22  refcount (u16)
//   base+24  THE OBJECT — so the refcount is at obj-2 and the chain head obj-8
//
// `malloc` / `free` come from libc, through the linker's import path.
pointer malloc(u32 n);
void free(pointer p);

// A class's `dealloc`, as the header stores it: one argument, the element.
typedef void xtDealloc_t(pointer);

pointer _xtc_alloc(u32 count, u32 stride, pointer dealloc)
    {
    // A count of 0 stays 0, so freeing `new C[0]` runs no dealloc (bug 472).
    u32 b = count * stride;
    if (b < (u32)256)
        b = (u32)256;
    u8* p = (u8*)malloc(b + (u32)24);
    if (p == (u8*)0)
        return (pointer)0;
    for (u32 i = (u32)0; i < b + (u32)24; i = i + (u32)1)
        p[i] = (u8)0;
    u32* w = (u32*)p;
    w[0] = (u32)$58544F42; // 'BOTX' — the header cookie
    w[1] = stride;
    w[2] = count;
    w[3] = (u32)dealloc;
    u16* rc = (u16*)(p + (u32)22);
    rc[0] = (u16)1; // one reference, at -2 from the object
    return (pointer)(p + (u32)24);
    }

// `.length` of a runtime-sized heap array (private:docs/bugs/045): the element count
// the allocator wrote at w[2] (base+8; the object is base+24). u16 by the
// language's `.length` contract.
u16 _xtc_count(pointer o)
    {
    u32* w = (u32*)((u8*)o - (u32)24);
    return (u16)w[2];
    }

void _xtc_dealloc(pointer o)
    {
    if (o == (pointer)0)
        return;
    // Weak slots pointing at this object read nil, not a dangling pointer —
    // and they are zeroed BEFORE the body runs, so a `dealloc` that reads a
    // weak back-pointer sees nil rather than a half-destroyed object.
    _xtc_weak_zero_for(o);
    u8* base = (u8*)o - (u32)24;
    u32* w = (u32*)base;
    u32 stride = w[1];
    u32 count = w[2];
    pointer* dslot = (pointer*)(base + (u32)12);
    xtDealloc_t* d = (xtDealloc_t*)dslot[0];
    if (d != (xtDealloc_t*)0)
        {
        // NON-RE-ENTRANT: bump the refcount to a high sentinel before running
        // the body, so a balanced retain/release inside it — the self-retain
        // bracket a method keeps around an opaque call — cannot fall back to
        // zero and dispatch `dealloc` again on the object being freed.
        u16* rc = (u16*)((u8*)o - (u32)2);
        rc[0] = (u16)$8000;
        // `delete arr` where arr is `new T[N]` runs the body per ELEMENT; the
        // header's count is what says how many.
        for (u32 i = (u32)0; i < count; i = i + (u32)1)
            d((pointer)((u8*)o + i * stride));
        }
    free((pointer)base);
    }

// ── Weak references: an intrusive doubly-linked list ──────────────
//
// No table, no cap, no scan — see private:docs/Design/weak-refs-intrusive.md. Each
// weak slot carries two hidden link words in front of it (the lowering
// reserves them in every position a `weak:T*` or `^` can occupy):
//
//   slot-8 = pprev    slot-4 = next    slot+0 = the referent
//
// and the object's chain head lives in its header at obj-8.
//
// `pprev` is the ADDRESS OF THE POINTER THAT POINTS AT THIS SLOT (the Linux
// hlist idiom), not the previous slot. Two things fall out of that, and both
// are load-bearing: unlinking is O(1) and never needs the object — which
// matters, because a WIDENED `^` holds a FUNCTION pointer in its referent
// word, so recovering the object by reading the slot would dereference
// `.text` as an object header — and `pprev != 0` is an unambiguous "am I
// linked?" test, where a plain `prev` cannot tell unlinked from head-of-chain.

// The two link words in front of a slot, as a two-element array.
pointer* _xtLinks(pointer* slot)
    {
    return (pointer*)((u8*)slot - (u32)8);
    }

// The chain head in an object's header, as a one-element array.
pointer* _xtWeakHead(pointer obj)
    {
    return (pointer*)((u8*)obj - (u32)8);
    }

void _xtc_weak_unregister(pointer* slot)
    {
    pointer* links = _xtLinks(slot);
    pointer* pp = (pointer*)links[0];
    if (pp == (pointer*)0)
        return; // not linked
    pointer* nx = (pointer*)links[1];
    pp[0] = (pointer)nx;
    if (nx != (pointer*)0)
        _xtLinks(nx)[0] = (pointer)pp;
    links[0] = (pointer)0;
    links[1] = (pointer)0;
    }

void _xtc_weak_register(pointer* slot, pointer obj)
    {
    _xtc_weak_unregister(slot); // drop any prior link
    if (obj == (pointer)0)
        return; // nothing to track
    // NOT-AN-OBJECT GUARD. `obj` here is the RECV word of a `^`, and for a
    // WIDENED `^` that word is a function pointer, not an object. An
    // address-based test cannot catch it across a `.so` — the loader binds a
    // defined symbol to the module that defines it, so the app's trampoline
    // and the library's are different addresses — and writing the chain head
    // through a function pointer aborts on real hardware. The cookie makes
    // the test value-based: fail it and this is simply not one of ours.
    u32* cookie = (u32*)((u8*)obj - (u32)24);
    if (cookie[0] != (u32)$58544F42)
        return;
    pointer* head = _xtWeakHead(obj);
    pointer* nx = (pointer*)head[0];
    pointer* links = _xtLinks(slot);
    links[0] = (pointer)head; // pprev = &head
    links[1] = (pointer)nx;
    // The next slot's pprev is the address of OUR next word.
    if (nx != (pointer*)0)
        _xtLinks(nx)[0] = (pointer)((u8*)links + (u32)4);
    head[0] = (pointer)slot;
    }

pointer _xtc_weak_load(pointer* slot)
    {
    return slot[0];
    }

void _xtc_weak_zero_for(pointer obj)
    {
    if (obj == (pointer)0)
        return;
    pointer* head = _xtWeakHead(obj);
    pointer* s = (pointer*)head[0]; // no weak refs — one test
    while (s != (pointer*)0)
        {
        pointer* links = _xtLinks(s);
        pointer* nx = (pointer*)links[1];
        s[0] = (pointer)0;
        links[0] = (pointer)0;
        links[1] = (pointer)0;
        s = nx;
        }
    head[0] = (pointer)0;
    }
