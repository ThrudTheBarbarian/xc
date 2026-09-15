// widen.stub.c — call widen(i8) → i16, print as signed.
#include <stdio.h>
#include <stdint.h>

extern int16_t widen(int8_t x);

int main(void)
    {
    printf("%d\n", (int)widen(-5));
    return 0;
    }
