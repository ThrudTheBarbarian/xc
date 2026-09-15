// loop.stub.c — call sum_to(10), print u16 result.
// Expected: 0+1+2+…+9 = 45.
#include <stdio.h>
#include <stdint.h>

extern uint16_t sum_to(uint8_t n);

int main(void)
    {
    printf("%u\n", (unsigned)sum_to(10));
    return 0;
    }
