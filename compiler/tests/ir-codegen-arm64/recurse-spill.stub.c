// recurse-spill.stub.c — call sumDown(5), print u16. Expected: 15.
#include <stdio.h>
#include <stdint.h>

extern uint16_t sumDown(uint8_t n);

int main(void)
    {
    printf("%u\n", (unsigned)sumDown(5));
    return 0;
    }
