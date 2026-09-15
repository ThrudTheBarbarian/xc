// struct-local.stub.c — call sp(), print the u16 result. Expected: 42.
#include <stdio.h>
#include <stdint.h>
extern uint16_t sp(void);
int main(void)
    {
    printf("%u\n", (unsigned)sp());
    return 0;
    }
