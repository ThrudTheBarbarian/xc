// range_init.xc — range expression as a fixed-size array initialiser:
//   u8  buf[10]  = 0..10;       // 0,1,2,3,4,5,6,7,8,9
//   u8  b2[5]    = 1...5;       // 1,2,3,4,5  (inclusive)
//   u16 buf3[4]  = 100..104;    // 100,101,102,103
//   i8  b4[3]    = -2..1;       // -2,-1,0
//
// Both bounds must constant-fold and the produced count must match
// the array's declared elementCount; sema rejects mismatches.
// Element type must be an integer scalar.
//
// Codegen path: emits a small unrolled run of `LDA #$.. / STA $..`
// pairs, one element-width chunk per slot. For a global array the
// bytes are baked into the data section.
//
// Element readback uses direct subscripts to sidestep an unrelated
// pre-existing bug in for-in over u16+ arrays (the indexed-load
// path advances Y by 1 per iteration regardless of element width).

#import "Stdio.xc"

u8 g_buf[10] = 0..10;     // global, baked into data section

void main(void)
{
    u16 fails = 0;

    // T1: u8 local, exclusive range, sums spot-check the slots.
    u8 buf[10] = 0..10;
    if (buf[0]  != 0)  fails++;
    if (buf[3]  != 3)  fails++;
    if (buf[7]  != 7)  fails++;
    if (buf[9]  != 9)  fails++;

    // T2: u8 local, inclusive range — count is end - start + 1.
    u8 b2[5] = 1...5;
    if (b2[0] != 1) fails++;
    if (b2[2] != 3) fails++;
    if (b2[4] != 5) fails++;

    // T3: u16 element type — values stored little-endian per slot.
    u16 buf3[4] = 100..104;
    if (buf3[0] != 100) fails++;
    if (buf3[1] != 101) fails++;
    if (buf3[2] != 102) fails++;
    if (buf3[3] != 103) fails++;

    // T4: signed range over i8 — wraparound stays correct.
    i8 b4[3] = -2..1;
    if (b4[0] != -2) fails++;
    if (b4[1] != -1) fails++;
    if (b4[2] !=  0) fails++;

    // T5: empty range — `5..5` produces 0 elements; the only legal
    // matching array is u8 b5[0]. xtc disallows zero-element arrays
    // in the parser, so the empty case is just unreachable here.
    // (Verified separately that the error message fires when the
    // bounds and array size disagree.)

    // T6: global array — same `0..10` shape, baked into the data
    // section rather than emitted as runtime stores.
    if (g_buf[0] != 0) fails++;
    if (g_buf[5] != 5) fails++;
    if (g_buf[9] != 9) fails++;

    if (fails == 0) Stdio.printf("DONE %u\n", (u16)17);
    else            Stdio.printf("FAIL %u\n", fails);
}
