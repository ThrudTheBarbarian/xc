// ternary.stub.c — mix() = then-arm 100 + else-arm 14 = 114.
#include <stdio.h>
#include <stdint.h>
extern uint16_t mix(void);
int main(void)
    {
    printf("%u\n", (unsigned)mix());
    return 0;
    }
