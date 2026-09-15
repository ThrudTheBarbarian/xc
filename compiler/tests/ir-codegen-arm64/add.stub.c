// add.stub.c — call the xtc-generated add(u8,u8), print the u8 result.
#include <stdio.h>
#include <stdint.h>

extern uint8_t add(uint8_t a, uint8_t b);

int main(void)
    {
    printf("%u\n", (unsigned)add(5, 6));
    return 0;
    }
