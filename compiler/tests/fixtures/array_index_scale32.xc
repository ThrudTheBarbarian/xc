//xtc-flags: target=arm64
// array_index_scale32.xc — arm64 regression: indexing an array whose element
// stride is a power of two > 16 (here a 32-byte struct) must NOT fuse into the
// extended-register add `add Xd,Xn,Wm,sxtw #5` (shift field caps at 4). The
// backend must sxtw the index into an X reg then `add ..., lsl #5`. An indirect
// index defeats strength-reduction so the ElementAddr is materialised. Was:
// "expected '[su]xt[bhw]' with optional integer in range [0, 4]" on arm64-macOS.
#import "Stdio.xc"
use Stdio;
struct S { i32 v0; i32 v1; i32 v2; i32 v3; i32 v4; i32 v5; i32 v6; i32 v7; }
void main(void)
{
    S arr[4];
    i32 idx[4]; idx[0]=3; idx[1]=1; idx[2]=0; idx[3]=2;
    i32 k;
    for (k = 0; k < 4; k = k + 1) arr[k].v0 = k * 100;
    i32 sum = 0;
    for (k = 0; k < 4; k = k + 1) sum = sum + arr[idx[k]].v0;
    printf("%d\n", sum);
}
