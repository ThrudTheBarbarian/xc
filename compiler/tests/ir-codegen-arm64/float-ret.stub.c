// float-ret.stub.c — run() sets gN = (i16)pi(), pi()=3.25 -> 3.
// Validates the arm64 float return ABI (pi returns in s0; run
// harvests s0 and fcvtzs to int). Expected: "3".
#include <stdio.h>
#include <stdint.h>

extern void run(void);
extern int16_t gN;

int main(void)
    {
    run();
    printf("%d\n", (int)gN);
    return 0;
    }
