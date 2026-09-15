// while-break-continue.stub.c — wsum(10): i counts up; skip adding 3
// (continue), stop at 7 (break) ⇒ 1+2+4+5+6 = 18.
#include <stdio.h>
#include <stdint.h>
extern uint16_t wsum(uint16_t n);
int main(void)
    {
    printf("%u\n", (unsigned)wsum(10));
    return 0;
    }
