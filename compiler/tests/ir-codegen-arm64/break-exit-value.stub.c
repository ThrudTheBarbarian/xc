// break-exit-value.stub.c — bsum(10): r bumped on i=0,1,2 then break ⇒ 30.
#include <stdio.h>
#include <stdint.h>
extern uint16_t bsum(uint16_t n);
int main(void)
    {
    printf("%u\n", (unsigned)bsum(10));
    return 0;
    }
