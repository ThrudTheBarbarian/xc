// float-param.stub.c — run() computes gResult = a*10 + s where
// a=(i16)addf(1.5,3.25)=4 and s=(i16)scalef(2,1.5,3)=1 -> 41.
// Validates AAPCS float params (addf: v0/v1; scalef: mixed
// x0/v0/x1 GP/FP counter split). Expected: "41".
#include <stdio.h>
#include <stdint.h>

extern void run(void);
extern int16_t gResult;

int main(void)
    {
    run();
    printf("%d\n", (int)gResult);
    return 0;
    }
