// class-arc.stub.c — pins the Retain / Release refcount discipline.
// `run()` allocates a Box, retains for the second strong slot, then
// scope-exits with two Releases (one per strong local). Refcount
// trace: +1 (alloc) +1 (retain) -1 (release b) -1 (release a) = 0,
// dealloc fires, prints DEALLOC. If Retain didn't bump or one of
// the Releases miscounted, the dealloc would fire too early or
// never.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern void run(void);

static int g_dealloc_count = 0;

void* _xtc_alloc(unsigned long count, unsigned long stride, void (*dealloc)(void*))
    {
    (void)count;
    (void)stride;
    (void)dealloc; // B1: generic allocator; this test's _xtc_dealloc handles teardown
    // 4-byte refcount at obj-4, matching the back end's 32-bit ldur/stur.
    // It was 2 bytes at obj-2 until the count was widened (task #46, because a
    // u16 WRAPS at 65,536 and freed live objects — bugs 025 and 079). This stub
    // is a THIRD place the object header is written down, after rt.c and the
    // back ends, and it is the one that caught the change: `make test` went red
    // here while everything else was green.
    uint8_t* p = (uint8_t*)malloc(256);
    *(uint32_t*)(p + 0) = 1; // refcount
    p[4] = 0;
    p[5] = 0; // vtbl slot
    p[6] = 0; // tag ivar
    return p + 4;
    }

void _xtc_dealloc(void* obj)
    {
    g_dealloc_count++;
    free((uint8_t*)obj - 4);
    }

int main(void)
    {
    run();
    printf("dealloc=%d\n", g_dealloc_count);
    return 0;
    }
