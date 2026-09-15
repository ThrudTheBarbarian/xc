// strlit.stub.c — firstchar() returns "Hi"[0] = 'H' = 72.
// Validates arm64 string-literal data emission + AddrOf + Load.
#include <stdio.h>
#include <stdint.h>

extern uint8_t firstchar(void);

int main(void)
    {
    printf("%u\n", (unsigned)firstchar());
    return 0;
    }
