#import "Stdio.xc"
#import "Assert.xc"

// Exercises the arm64 variable-trip partial unroller: single-induction,
// store-only loops (which it unrolls ×4 with inline guards) across trip counts
// that hit every remainder phase (n mod 4 = 0,1,2,3 and the n<4 short cases).
// A wrong remainder / CFG splice would corrupt the array tail or count.
u16 arr[16];

void main(void) {
    Assert.reset();
    u16 n;
    for (n = 0; n <= 9; n = n + 1) {
        u16 i;
        for (i = 0; i < 16; i = i + 1) arr[i] = 999;     // unrolled clear
        for (i = 0; i < n; i = i + 1) arr[i] = i * 10;   // unrolled, trip = n
        u16 sum = 0;
        u16 j;
        for (j = 0; j < 16; j = j + 1) sum = sum + arr[j];
        // sum = 10*(0+..+(n-1)) + 999*(16-n)
        u16 expect = (u16)(5 * n * (n - 1) + 999 * (16 - n));
        Assert.isEqual(sum, expect);                     // Tn+1
    }
    Stdio.printf("DONE 10\n");
}
