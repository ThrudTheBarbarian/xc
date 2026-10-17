//xtc-flags: target=arm64 --par-auto
// par_auto_while.xc — --par-auto takes a counted while loop as the `for` it
// amounts to: `while (v < B) { …; v++; }` with v written nowhere else. After
// it, v holds what the loop left in it. A map, an inclusive reduction, a loop
// that never runs, and one with a `break` that stays as written.
#import "Stdio.xc"
#import "Par.xc"
#define N 100000
u32 a[N];
i32 main(void)
    {
    u32 i = (u32)0;
    while (i < (u32)N)
        {
        a[i] = i * (u32)3 + (u32)1;
        i++;
        }
    u32 j = (u32)5;
    u32 sum = (u32)0;
    while (j <= (u32)90000)
        {
        sum = sum + a[j];
        j += 1;
        }
    u32 k = (u32)10;
    u32 none = (u32)0;
    while (k < (u32)5)
        {
        none = none + (u32)1;
        k = k + 1;
        }
    u32 m = (u32)0;
    while (m < (u32)N)
        {
        if (a[m] > (u32)1000)
            break;
        m++;
        }
    Stdio.printf("i=%u a[777]=%u j=%u sum=%u k=%u none=%u m=%u\n", i, a[777], j, sum, k, none, m);
    return 0;
    }
