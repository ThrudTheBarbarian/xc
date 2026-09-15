// byte-list-aggregate.stub.c — call run(), print u16. Expected: 362.
#include <stdio.h>
#include <stdint.h>
extern uint16_t run(void);
int main(void)
    {
    printf("%u\n", (unsigned)run());
    return 0;
    }
