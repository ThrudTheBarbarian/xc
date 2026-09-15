// for-continue.stub.c — fsum(10): sum 0..9 skipping 3 = 42.
#include <stdio.h>
#include <stdint.h>
extern uint16_t fsum(uint16_t n);
int main(void)
    {
    printf("%u\n", (unsigned)fsum(10));
    return 0;
    }
