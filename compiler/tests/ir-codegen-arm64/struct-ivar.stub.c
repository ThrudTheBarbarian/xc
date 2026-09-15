// struct-ivar.stub.c — link arm64-generated struct-ivar against a tiny
// runtime. Box layout: slot 0 = vtable ptr (2 bytes), slot 1 = Point at
// (u16 x, u16 y = 4 bytes). 1 refcount byte at offset −1 + 6 payload.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern uint16_t si(void);

void* _xtc_alloc(unsigned long count, unsigned long stride, void (*dealloc)(void*))
    {
    (void)count;
    (void)stride;
    (void)dealloc; // B1: generic allocator
    uint8_t* p = (uint8_t*)malloc(256);
    // 4-byte refcount at obj-4, matching the back end's 32-bit ldur/stur
    // (task #46). This stub does not exercise ARC, so it passed with the old
    // 2-byte header — but a stub whose object layout disagrees with the back
    // end is a trap waiting for whoever adds a retain to this test.
    *(uint32_t*)p = 1; // refcount starts at 1
    for (int i = 1; i <= 6; i++)
        p[i] = 0; // vtbl ptr + Point payload
    return p + 4; // user-visible pointer skips refcount
    }

void _xtc_dealloc(void* obj)
    {
    free((uint8_t*)obj - 4);
    }

int main(void)
    {
    printf("%u\n", (unsigned)si());
    return 0;
    }
