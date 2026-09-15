// icmp-eq.stub.c — cmp(7): NE(+2) + UGT(+4) = 6.
#include <stdio.h>
#include <stdint.h>
extern uint16_t cmp(uint16_t n);
int main(void)
    {
    printf("%u\n", (unsigned)cmp(7));
    return 0;
    }
