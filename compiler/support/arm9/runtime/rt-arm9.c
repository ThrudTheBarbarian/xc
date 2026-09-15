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

// rt-arm9.c — the SOURCE of support/arm9/runtime/rtgen-arm9.s.
//
// Compiled to assembly ONCE and the assembly checked in, so a build needs no C
// compiler: exactly the arrangement rtgen-linux.s has on x86-64. Regenerate with
//   arm-none-eabi-gcc -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=vfpv3 -O2 -fPIC \
//       -S -o support/arm9/runtime/rtgen-arm9.s <this file>
// and check the result in.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern int xt_main(void);
void _xt_capture_args(int, char**);
int main(int argc, char** argv)
    {
    _xt_capture_args(argc, argv);
    return xt_main();
    }

uint16_t _xtc_count(void* o)
    {
    return (uint16_t)*(uint32_t*)((uint8_t*)o - 16);
    }

void* _xtc_alloc(unsigned long count, unsigned long stride, void (*dealloc)(void*))
    {
    if (count < 1)
        count = 1;
    unsigned long b = count * stride;
    if (b < 256)
        b = 256;
    uint8_t* p = (uint8_t*)calloc(1, b + 24);
    if (!p)
        {
        fprintf(stderr, "xcc: out of memory (%lu x %lu bytes)\n", count, stride);
        abort();
        }
    *(uint32_t*)(p + 0) = 0x58544F42U;
    *(uint32_t*)(p + 4) = (uint32_t)stride;
    *(uint32_t*)(p + 8) = (uint32_t)count;
    *(void (**)(void*))(p + 12) = dealloc;
    *(void**)(p + 16) = 0;
    *(uint16_t*)(p + 22) = 1;
    return p + 24;
    }

#define _XT_WH(o) (*(void***)((uint8_t*)(o) - 8))
void _xtc_weak_unregister(void** slot)
    {
    void*** pp = (void***)slot[-2];
    if (!pp)
        return;
    /* Back-pointer invariant: *pprev == slot for a validly-linked slot. Stale
       union bytes can leave a non-null but bogus pprev; writing through it
       faults (bug 176). Verify before unlinking. */
    if (*pp != slot)
        {
        slot[-2] = 0;
        slot[-1] = 0;
        return;
        }
    void** nx = (void**)slot[-1];
    *pp = nx;
    if (nx)
        nx[-2] = (void*)pp;
    slot[-2] = 0;
    slot[-1] = 0;
    }
void _xtc_weak_register(void** slot, void* obj)
    {
    _xtc_weak_unregister(slot);
    if (!obj)
        return;
    if (*(uint32_t*)((uint8_t*)obj - 24) != 0x58544F42U)
        return;
    void** nx = _XT_WH(obj);
    slot[-2] = (void*)&_XT_WH(obj);
    slot[-1] = (void*)nx;
    if (nx)
        nx[-2] = (void*)&slot[-1];
    _XT_WH(obj) = slot;
    }
void* _xtc_weak_load(void** slot)
    {
    return *slot;
    }
void _xtc_weak_zero_for(void* obj)
    {
    if (!obj)
        return;
    void** s = _XT_WH(obj);
    while (s)
        {
        void** nx = (void**)s[-1];
        *s = 0;
        s[-2] = 0;
        s[-1] = 0;
        s = nx;
        }
    _XT_WH(obj) = 0;
    }

void _xtc_dealloc(void* o)
    {
    _xtc_weak_zero_for(o);
    uint8_t* base = (uint8_t*)o - 24;
    unsigned long stride = *(uint32_t*)(base + 4);
    unsigned long count = *(uint32_t*)(base + 8);
    void (*d)(void*) = *(void (**)(void*))(base + 12);
    if (d)
        {
        *(unsigned short*)((uint8_t*)o - 2) = 0x8000u;
        for (unsigned long i = 0; i < count; i++)
            d((uint8_t*)o + i * stride);
        }
    free(base);
    }

static void* _xtc_bank_regions[3][256] = {{0}};
void* _xtc_bank(uint8_t type, uint8_t idx)
    {
    if (type > 1)
        return 0;
    if (!_xtc_bank_regions[type][idx])
        _xtc_bank_regions[type][idx] = calloc(1, 12288);
    return _xtc_bank_regions[type][idx];
    }
