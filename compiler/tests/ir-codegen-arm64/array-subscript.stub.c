// array-subscript.stub.c — call sa(), print the u8 result. Expected: 42.
#include <stdio.h>
#include <stdint.h>
extern uint8_t sa(void);
int main(void)
    {
    printf("%u\n", (unsigned)sa());
    return 0;
    }
