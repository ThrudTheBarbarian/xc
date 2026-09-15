// loop-postfix.stub.c — call sum_postfix(), print u16 result.
// Expected: 0+1+2+…+9 = 45 (proves the i++ loop terminates).
#include <stdio.h>
#include <stdint.h>

extern uint16_t sum_postfix(void);

int main(void)
    {
    printf("%u\n", (unsigned)sum_postfix());
    return 0;
    }
