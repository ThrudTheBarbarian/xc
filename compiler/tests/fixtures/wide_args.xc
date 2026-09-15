#import "Stdio.xc"
u32 addU32(u32 a, u32 b, u32 c) { return a + b + c; }
u32 mulU32(u32 a, u32 b) { return a * b; }
float addF(float a, float b, float c) { return a + b + c; }
float mulF(float a, float b) { return a * b; }

void main(void) {
    u32 r;
    u32 lU = 50000;
    float f;
    float two = 2.0;
    float threeF = 3.25;

    r = addU32(100000, 200000, 50000);
    if (r == 350000) { Stdio.printf("T1 PASS\n"); } else { Stdio.printf("T1 FAIL\n"); }
    r = mulU32(1000, 1000);
    if (r == 1000000) { Stdio.printf("T2 PASS\n"); } else { Stdio.printf("T2 FAIL\n"); }
    r = addU32(lU, lU, lU);
    if (r == 150000) { Stdio.printf("T3 PASS\n"); } else { Stdio.printf("T3 FAIL\n"); }
    f = addF(1.5, 2.5, 1.0);
    if (f == 5.0) { Stdio.printf("T4 PASS\n"); } else { Stdio.printf("T4 FAIL\n"); }
    f = mulF(3.0, 4.0);
    if (f == 12.0) { Stdio.printf("T5 PASS\n"); } else { Stdio.printf("T5 FAIL\n"); }
    f = mulF(threeF, two);
    if (f == 6.5) { Stdio.printf("T6 PASS\n"); } else { Stdio.printf("T6 FAIL\n"); }
}
