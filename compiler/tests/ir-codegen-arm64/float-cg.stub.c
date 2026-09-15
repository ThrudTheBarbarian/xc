// float-cg.stub.c — run() sets gR = (i16)(gA + gB) with gA=1.5,
// gB=3.25 -> 4. Validates arm64 native FAdd + FpToSI + float Const.
#include <stdio.h>
#include <stdint.h>

extern void run(void);
extern int16_t gR;

int main(void)
    {
    run();
    printf("%d\n", (int)gR);
    return 0;
    }
