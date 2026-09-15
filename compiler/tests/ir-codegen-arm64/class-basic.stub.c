// class-basic.stub.c — link the arm64-generated class-basic against
// a tiny runtime: malloc-backed _xtc_new_Foo and free-backed
// _xtc_dealloc. The Foo layout matches the IR lowering's instance
// shape (slot 0 = vtable ptr placeholder, slot 1 = x:U8 at byte
// offset 2). The refcount byte lives at offset −1 from the
// returned pointer; the IR's Retain / Release ops dec/inc it.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern uint8_t run(void);

void* _xtc_alloc(unsigned long count, unsigned long stride, void (*dealloc)(void*))
    {
    (void)count;
    (void)stride;
    (void)dealloc; // B1: generic allocator
    // 1 (refcount) + 3 (Foo: 2-byte vtbl slot + 1-byte x).
    uint8_t* p = (uint8_t*)malloc(256);
    // 4-byte refcount at obj-4, matching the back end's 32-bit ldur/stur
    // (task #46). This stub does not exercise ARC, so it passed with the old
    // 2-byte header — but a stub whose object layout disagrees with the back
    // end is a trap waiting for whoever adds a retain to this test.
    *(uint32_t*)p = 1; // refcount starts at 1
    p[4] = 0;
    p[5] = 0;     // vtable ptr placeholder
    p[6] = 0;     // x = 0
    return p + 4; // user-visible pointer skips refcount
    }

void _xtc_dealloc(void* obj)
    {
    free((uint8_t*)obj - 4);
    }

int main(void)
    {
    printf("%u\n", (unsigned)run());
    return 0;
    }
