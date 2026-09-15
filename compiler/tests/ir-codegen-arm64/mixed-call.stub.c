// mixed-call.stub.c — call run(), print its u16 return.
#include <stdio.h>
#include <stdint.h>

extern uint16_t run(void);

int main(void)
    {
    printf("%u\n", (unsigned)run());
    return 0;
    }
