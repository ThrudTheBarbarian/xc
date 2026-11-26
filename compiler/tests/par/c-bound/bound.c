/* bound.c — the overlap guard's range check for reads bounded by an inner
   loop (tests/par/guard-bound.sh). Each loop stores out[i] and reads in[]
   away from [i]: in[j] for j < n, n from outside the loop (nbody's shape);
   in[j] and in[i] together; in[j] for j <= i; in[j] for j < n stepping by
   4. Each runs three times: out and in from two allocations, from one
   allocation without overlap, and overlapping (where only a serial run
   gives the right answer). The arrays are under 64 KB, from the C
   library's malloc. Prints a checksum per call. */
#include <stdio.h>
#include <stdlib.h>

__attribute__((noinline)) void byValue(int* out, const int* in, long n)
{
    for (long i = 0; i < n; i++) { /* LOOP-VALUE */
        int s = 0;
        for (long j = 0; j < n; j++)
            s += in[j] * (int)(j & 7);
        out[i] = s + (int)i;
    }
}

__attribute__((noinline)) void mixed(int* out, const int* in, long n)
{
    for (long i = 0; i < n; i++) { /* LOOP-MIXED */
        int s = 0;
        for (long j = 0; j < n; j++)
            s += in[j] - in[i];
        out[i] = s;
    }
}

__attribute__((noinline)) void upTo(int* out, const int* in, long n)
{
    for (long i = 0; i < n; i++) { /* LOOP-UPTO */
        int s = 0;
        for (long j = 0; j <= i; j++)
            s += in[j];
        out[i] = s;
    }
}

__attribute__((noinline)) void stepped(int* out, const int* in, long n)
{
    for (long i = 0; i < n; i++) { /* LOOP-STEP */
        int s = 0;
        for (long j = 1; j < n; j += 4)
            s += in[j] ^ (int)i;
        out[i] = s;
    }
}

static unsigned sum(const int* a, long n)
{
    unsigned s = 0;
    for (long i = 0; i < n; i++)
        s = s * 31u + (unsigned)a[i];
    return s;
}

static void fill(int* a, long n)
{
    for (long i = 0; i < n; i++)
        a[i] = (int)((i * 7 + 3) % 101);
}

typedef void (*Loop)(int*, const int*, long);

int main(int argc, char** argv)
{
    long n = argc > 1 ? atol(argv[1]) : 3000;
    Loop loops[4] = {byValue, mixed, upTo, stepped};
    for (int k = 0; k < 4; k++) {
        /* Two allocations. */
        int* in = malloc(n * sizeof(int));
        int* out = malloc(n * sizeof(int));
        fill(in, n);
        loops[k](out, in, n);
        printf("%u ", sum(out, n));
        free(in);
        free(out);
        /* One allocation: in, then out after it. */
        int* both = malloc(2 * n * sizeof(int));
        fill(both, 2 * n);
        loops[k](both + n, both, n);
        printf("%u ", sum(both, 2 * n));
        /* Overlapping: out starts half way through in. */
        fill(both, 2 * n);
        loops[k](both + n / 2, both, n);
        printf("%u\n", sum(both, 2 * n));
        free(both);
    }
    return 0;
}
