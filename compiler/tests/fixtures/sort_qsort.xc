// sort_qsort.xc — Sort.qsort driven by user-supplied comparators.
//
// Exercises the stage-2 call-site-local CFA: &ascending and
// &descending are passed as fn-pointer arguments to Sort.qsort,
// which then calls them through `cmp(a, b)`. The comparators are
// non-recursive and their only &-of uses are in these call sites,
// so sema keeps them static-frame eligible (verifiable with
// XTC_DEBUG_STATIC_FRAME=1 at compile time).
//
// Covers:
//   T1  ascending sort of a shuffled array
//   T2  descending sort of the same data
//   T3  already-sorted input (worst case for Lomuto pivot-at-hi)
//   T4  all-equal input
//   T5  length-1 and length-0 no-ops

#import "Stdio.xc"
#import "Sort.xc"

i16 ascending(u16 a, u16 b)
{
    if (a < b) { return (i16)-1; }
    if (a > b) { return (i16)1; }
    return (i16)0;
}

i16 descending(u16 a, u16 b)
{
    if (a < b) { return (i16)1; }
    if (a > b) { return (i16)-1; }
    return (i16)0;
}

bool isSortedAsc(u16* a, u16 n)
{
    u16 i = (u16)1;
    while (i < n) {
        if (a[i - (u16)1] > a[i]) { return false; }
        i = i + (u16)1;
    }
    return true;
}

bool isSortedDesc(u16* a, u16 n)
{
    u16 i = (u16)1;
    while (i < n) {
        if (a[i - (u16)1] < a[i]) { return false; }
        i = i + (u16)1;
    }
    return true;
}

void main(void)
{
    // Local-stack array: global-array decay to pointer is currently
    // broken (`&buf[0]` drops the high byte and bare `buf` as rvalue
    // does similar), so keep the array on the function's local stack
    // where the bare-name form of decay works correctly.
    u16 buf[8];

    // T1: ascending sort of a shuffled 8-element array.
    buf[0] = 5; buf[1] = 3; buf[2] = 8; buf[3] = 1;
    buf[4] = 9; buf[5] = 2; buf[6] = 7; buf[7] = 4;
    Sort.qsort(buf, (u16)8, &ascending);
    if (isSortedAsc(buf, (u16)8) &&
        buf[0] == 1 && buf[7] == 9) { Stdio.printf("T1 PASS\n"); }
    else { Stdio.printf("T1 FAIL a[0]=%u a[7]=%u\n", buf[0], buf[7]); }

    // T2: descending sort of the same data.
    buf[0] = 5; buf[1] = 3; buf[2] = 8; buf[3] = 1;
    buf[4] = 9; buf[5] = 2; buf[6] = 7; buf[7] = 4;
    Sort.qsort(buf, (u16)8, &descending);
    if (isSortedDesc(buf, (u16)8) &&
        buf[0] == 9 && buf[7] == 1) { Stdio.printf("T2 PASS\n"); }
    else { Stdio.printf("T2 FAIL a[0]=%u a[7]=%u\n", buf[0], buf[7]); }

    // T3: already-sorted input — worst-case recursion depth for
    // Lomuto with pivot-at-hi.
    buf[0] = 1; buf[1] = 2; buf[2] = 3; buf[3] = 4;
    buf[4] = 5; buf[5] = 6; buf[6] = 7; buf[7] = 8;
    Sort.qsort(buf, (u16)8, &ascending);
    if (isSortedAsc(buf, (u16)8) &&
        buf[0] == 1 && buf[7] == 8) { Stdio.printf("T3 PASS\n"); }
    else { Stdio.printf("T3 FAIL\n"); }

    // T4: all-equal input.
    buf[0] = 7; buf[1] = 7; buf[2] = 7; buf[3] = 7;
    buf[4] = 7; buf[5] = 7; buf[6] = 7; buf[7] = 7;
    Sort.qsort(buf, (u16)8, &ascending);
    if (buf[0] == 7 && buf[4] == 7 && buf[7] == 7) { Stdio.printf("T4 PASS\n"); }
    else { Stdio.printf("T4 FAIL\n"); }

    // T5: length-0 and length-1 are no-ops.
    Sort.qsort(buf, (u16)0, &ascending);  // must not touch memory
    Sort.qsort(buf, (u16)1, &ascending);  // likewise
    if (buf[0] == 7) { Stdio.printf("T5 PASS\n"); }
    else { Stdio.printf("T5 FAIL\n"); }
}
