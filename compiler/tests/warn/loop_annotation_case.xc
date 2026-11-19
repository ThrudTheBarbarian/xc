//xtc-warn: Unknown loop annotation 'Serial'
//xtc-warn: Unknown loop annotation 'UNROLL'
//xtc-warn: Unknown loop annotation 'Unroll'
// Loop annotations are matched in lower case only, as documented: `: serial`,
// `: unroll` and `: goal(...)`. Another spelling is an unknown annotation,
// and --par-style=auto does not read `: Serial` as `: serial`.
#import "Stdio.xc"
u32 a[100000];
i32 main(void)
    {
    u32 n = 100000;
    for (u32 i in 0..n) : Serial { a[i] = i; }
    for (u32 i = 0; i < n; i++) : UNROLL a[i] = a[i] + 1;
    for (u32 i in 0..n) : serial, Unroll { a[i] = a[i] + 2; }
    Stdio.printf("%u\n", a[7]);
    return 0;
    }
