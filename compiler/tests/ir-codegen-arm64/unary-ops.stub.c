// unary-ops.stub.c — call un(), print the u16 result. Expected: 42.
#include <stdio.h>
#include <stdint.h>
extern uint16_t un(void);
int main(void)
    {
    printf("%u\n", (unsigned)un());
    return 0;
    }
