#import "Stdio.xc"
#import "Assert.xc"

// Exercises the arm64 memset-idiom recogniser: `for(i=0;i<cmp>N;i++)arr[i]=C`
// over a byte array with constant N and C becomes a memset. Checks both bounds
// (ULE/ULT), that adjacent cells are untouched, and that an index-dependent
// fill is NOT mis-recognised (must stay a real loop).
u8 a[300];

void main(void) {
    Assert.reset();
    u16 j;

    // ULE: fill a[0..255] = 7 (256 bytes); a[256..257] are sentinels.
    a[256] = (u8)99; a[257] = (u8)99;
    for (j = 0; j <= 255; j = j + 1) a[j] = (u8)7;
    u16 s = 0;
    for (j = 0; j < 258; j = j + 1) s = s + a[j];
    Assert.isEqual(s, (u16)(256 * 7 + 99 + 99));         // T1: 1990, sentinels intact

    // ULT: fill a[0..99] = 0.
    for (j = 0; j < 100; j = j + 1) a[j] = (u8)0;
    u16 s2 = 0;
    for (j = 0; j < 100; j = j + 1) s2 = s2 + a[j];
    Assert.isEqual(s2, 0);                               // T2

    // Index-dependent fill — NOT a memset; must stay a loop and stay correct.
    for (j = 0; j < 50; j = j + 1) a[j] = (u8)j;
    u16 s3 = 0;
    for (j = 0; j < 50; j = j + 1) s3 = s3 + a[j];
    Assert.isEqual(s3, 1225);                            // T3: 0+..+49

    Stdio.printf("DONE 3\n");
}
