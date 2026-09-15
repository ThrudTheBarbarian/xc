#import "Stdio.xc"
#import "Assert.xc"

// Exercises the arm64 no-wrap (induction-bound) analysis from both sides:
// loop induction variables whose increment provably fits the type (the mask
// may be dropped — result must stay correct) AND arithmetic that genuinely
// wraps (the mask must be kept). A miscompile here flips a value.
void main(void) {
    Assert.reset();

    // T1 — bounded u16 induction sum (i guarded < 100, i+1 ≤ 100, no wrap).
    u16 acc = 0;
    for (u16 i = 0; i < 100; i = i + 1) acc = acc + i;
    Assert.isEqual(acc, 4950);                       // T1

    // T2 — non-induction u8 add that genuinely wraps (mask must be kept):
    // 200 + 100 = 300 → 300 & $FF = 44.
    u8 b = (u8)200;
    b = b + (u8)100;
    Assert.isEqual((u16)b, 44);                      // T2

    // T3 — bounded u16 induction with a large step, no overflow:
    // i = 0,10000,…,50000 (< 60000) then 60000 exits → 6 iterations.
    u16 cnt = 0;
    for (u16 i = 0; i < 60000; i = i + 10000) cnt = cnt + 1;
    Assert.isEqual(cnt, 6);                           // T3

    // T4 — the induction exit value itself (60000 ≤ 65535, mask droppable):
    u16 j;
    for (j = 0; j <= 50000; j = j + 10000) {}
    Assert.isEqual(j, 60000);                         // T4

    // T5 — bounded u8 induction (k < 50, k+1 ≤ 50 ≤ 255, no wrap).
    u8 s = 0;
    for (u8 k = 0; k < 50; k = k + 1) s = s + (u8)1;
    Assert.isEqual((u16)s, 50);                       // T5

    Stdio.printf("DONE 5\n");
}
