// byte-list-init.stub.c — bl(): (u16)0x12345678 + (u16)3.0 = 22139.
#include <stdio.h>
#include <stdint.h>
extern uint16_t bl(void);
int main(void)
    {
    printf("%u\n", (unsigned)bl());
    return 0;
    }
