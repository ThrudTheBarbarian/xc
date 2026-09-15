// short-circuit.stub.c — sc() = 1 + 4 + 8 = 13.
#include <stdio.h>
#include <stdint.h>
extern uint16_t sc(void);
int main(void)
    {
    printf("%u\n", (unsigned)sc());
    return 0;
    }
