// self-method-call.stub.c — count3() calls Counter.run(), which calls
// the sibling method _bump() three times via implicit self. Expects 3.
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
extern uint16_t count3(void);
/* 4-byte refcount at obj-4, task #46 */
void* _xtc_alloc(unsigned long c, unsigned long s, void (*d)(void*))
    {
    (void)c;
    (void)s;
    (void)d;
    uint8_t* p = (uint8_t*)malloc(256);
    *(uint32_t*)p = 1;
    return p + 4;
    }
void _xtc_dealloc(void* o)
    {
    free((uint8_t*)o - 4);
    }
int main(void)
    {
    printf("%u\n", (unsigned)count3());
    return 0;
    }
