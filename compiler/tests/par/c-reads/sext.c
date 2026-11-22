// c-reads.sh: `x ? -1 : 0` is `sext i1` in clang's optimised IR (the
// reader once widened it to 1: libstdc++'s deque counted its size wrong).
#include <stdio.h>

__attribute__((noinline)) long negflag(long x) { return x ? -1L : 0L; }

int main(void) {
    long s = 0;
    for (long i = -5; i < 6; i++)
        s = s * 3 + negflag(i & 3);
    printf("%ld %ld %ld\n", s, negflag(0), negflag(7));
    return 0;
}
