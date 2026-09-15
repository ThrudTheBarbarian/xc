// array_slice.xc — for-in over an array slice expression on a
// fixed-size array. Four slice shapes plus inclusive variant.
//
//   arr[m..n]   half-open slice from m (inclusive) to n (exclusive)
//   arr[m...n]  closed slice — inclusive on both ends
//   arr[..n]    open-start, equivalent to arr[0..n]
//   arr[m..]    open-end, equivalent to arr[m..arr.length]
//
// The codegen lowers the slice to a counted iteration with the
// counter starting at `m` (or 0) and exiting when it would reach
// `n` (or arr.length). Inclusive form biases the cap by +1 at
// loop setup so the inner compare stays a plain `idx < cap`.
//
// Heap-pointer slicing is covered by array_slice_heap.xc on
// heap-capable targets — bump-allocator targets (xl/xt/xe) don't
// write a heap header so `arr[m..]` (open-end on a heap pointer)
// would read garbage for the cap.

#import "Stdio.xc"

void main(void)
{
    u16 fails = 0;

    u8 arr[10] = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };

    // T1: arr[2..5] should sum 30 + 40 + 50 = 120.
    u16 t1 = 0;
    for (u8 v in arr[2..5]) t1 = t1 + v;
    if (t1 != 120) fails++;

    // T2: arr[..3] should sum 10 + 20 + 30 = 60.
    u16 t2 = 0;
    for (u8 v in arr[..3]) t2 = t2 + v;
    if (t2 != 60) fails++;

    // T3: arr[7..] should sum 80 + 90 + 100 = 270.
    u16 t3 = 0;
    for (u8 v in arr[7..]) t3 = t3 + v;
    if (t3 != 270) fails++;

    // T4: arr[2...4] inclusive should sum 30 + 40 + 50 = 120.
    u16 t4 = 0;
    for (u8 v in arr[2...4]) t4 = t4 + v;
    if (t4 != 120) fails++;

    // T5: arr[0..arr.length] should sum every element = 550.
    u16 t5 = 0;
    for (u8 v in arr[0..arr.length]) t5 = t5 + v;
    if (t5 != 550) fails++;

    // T6: empty slice — bounds where m == n: zero iterations.
    u16 t6 = 0;
    for (u8 v in arr[5..5]) t6 = t6 + v;
    if (t6 != 0) fails++;

    if (fails == 0) Stdio.printf("DONE 6\n");
    else            Stdio.printf("FAIL %u\n", fails);
}
