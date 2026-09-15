// static-field.stub.c — three Counter.bump() then Counter.get() == 3.
// Validates static-method class-field access via __sdata on arm64.
#include <stdio.h>
#include <stdint.h>
extern uint16_t run(void);
int main(void)
    {
    printf("%u\n", (unsigned)run());
    return 0;
    }
