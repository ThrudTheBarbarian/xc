// Switches: cases sharing a target, a case that goes to the default,
// negative and wide cases, a switch on a char and on a 64-bit value, and
// (in clang's optimised IR) a phi in the join block whose entries come
// from the switch's block.
#include <stdio.h>
#include <stdint.h>

static int classify(int c)
    {
    switch (c)
        {
        case 'a': case 'e': case 'i': case 'o': case 'u': return 1;
        case ' ': return 2;
        case '0': case '1': case '2': case '3': return 3;
        case -7: return 4;
        case 1000000: return 9;
        default: return 0;
        }
    }

__attribute__((noinline)) int pick(int c)
    {
    int r;
    switch (c & 7)
        {
        case 1: r = 5; break;
        case 2: r = 7; break;
        case 4: case 6: r = c * 3; break;
        case 5: r = 0; break;
        default: r = -1; break;
        }
    return r + 1;
    }

static int narrow(signed char c)
    {
    switch (c)
        {
        case -128: return 1;
        case -1: return 2;
        case 127: return 3;
        default: return 0;
        }
    }

static int wide(int64_t v)
    {
    switch (v)
        {
        case 0x100000000LL: return 1;
        case -0x100000001LL: return 2;
        case 5: return 3;
        default: return 0;
        }
    }

int main(void)
    {
    int n[10] = {0};
    long s = 0;
    for (int i = 0; i < 200000; i++)
        {
        int c = (i * 7919) % 1100 - 10;
        n[classify(c == 999 ? 1000000 : c)]++;
        s += pick(i) + narrow((signed char)i);
        }
    s += wide(0x100000000LL) * 10 + wide(-0x100000001LL) * 100 + wide(5) * 1000 + wide(6);
    for (int k = 0; k < 10; k++)
        printf("%d ", n[k]);
    printf("%ld\n", s);
    return 0;
    }
