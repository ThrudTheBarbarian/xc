// for_range.xc — `for (T? var in start..end)` range syntax with
// optional `step <signed-int-literal>` clause.
//
// Direction:
//   - explicit `step <neg>` → descending
//   - else literal bounds with start > end → descending (auto-flip)
//   - else ascending (default +1)
//
// Comparison:
//   asc exclusive `..`   → i <  end
//   asc inclusive `...`  → i <= end
//   desc exclusive `..`  → i >  end
//   desc inclusive `...` → i >= end
//
// Loop variable type defaults to u8 when both bounds are u8 literals
// AND the step magnitude fits in u8; non-literal bounds (or u16+
// literals) require an explicit type.

#import "Stdio.xc"

void main(void)
{
    // T1: exclusive `0..5` → 5 iterations (0, 1, 2, 3, 4).
    u8 sum = 0;
    for (u8 i in 0..5) {
        sum = sum + i;
    }
    if (sum == 10) { Stdio.printf("T1 PASS\n"); }
    else           { Stdio.printf("T1 FAIL sum=%u\n", sum); }

    // T2: inclusive `0...5` → 6 iterations (0, 1, 2, 3, 4, 5).
    sum = 0;
    for (u8 i in 0...5) {
        sum = sum + i;
    }
    if (sum == 15) { Stdio.printf("T2 PASS\n"); }
    else           { Stdio.printf("T2 FAIL sum=%u\n", sum); }

    // T3: type defaults to u8 when both bounds are u8 literals.
    u8 count = 0;
    for (i in 1..4) {
        count = count + 1;
    }
    if (count == 3) { Stdio.printf("T3 PASS\n"); }
    else            { Stdio.printf("T3 FAIL count=%u\n", count); }

    // T4: explicit u16 type with bounds beyond u8.
    u16 total = 0;
    for (u16 i in 250..260) {
        total = total + 1;
    }
    if (total == 10) { Stdio.printf("T4 PASS\n"); }
    else             { Stdio.printf("T4 FAIL total=%u\n", total); }

    // T5: inclusive across the u8 boundary.
    total = 0;
    for (u16 i in 254...256) {
        total = total + 1;
    }
    if (total == 3) { Stdio.printf("T5 PASS\n"); }
    else            { Stdio.printf("T5 FAIL total=%u\n", total); }

    // T6: empty exclusive range `5..5` → 0 iterations.
    count = 0;
    for (u8 i in 5..5) {
        count = count + 1;
    }
    if (count == 0) { Stdio.printf("T6 PASS\n"); }
    else            { Stdio.printf("T6 FAIL count=%u\n", count); }

    // T7: single-element inclusive `5...5` → 1 iteration.
    count = 0;
    for (u8 i in 5...5) {
        count = count + 1;
    }
    if (count == 1) { Stdio.printf("T7 PASS\n"); }
    else            { Stdio.printf("T7 FAIL count=%u\n", count); }

    // T8: non-literal bounds (ascending only by default).
    u8 lo = 2;
    u8 hi = 7;
    sum = 0;
    for (u8 i in lo..hi) {
        sum = sum + i;
    }
    if (sum == 20) { Stdio.printf("T8 PASS\n"); }   // 2+3+4+5+6
    else           { Stdio.printf("T8 FAIL sum=%u\n", sum); }

    // T9: ascending step. `0..10 step 2` → 0, 2, 4, 6, 8 (5 iters).
    sum = 0;
    for (u8 i in 0..10 step 2) {
        sum = sum + i;
    }
    if (sum == 20) { Stdio.printf("T9 PASS\n"); }   // 0+2+4+6+8
    else           { Stdio.printf("T9 FAIL sum=%u\n", sum); }

    // T10: ascending step inclusive. `0...10 step 2` → 0,2,4,6,8,10.
    sum = 0;
    for (u8 i in 0...10 step 2) {
        sum = sum + i;
    }
    if (sum == 30) { Stdio.printf("T10 PASS\n"); }  // 0+2+4+6+8+10
    else           { Stdio.printf("T10 FAIL sum=%u\n", sum); }

    // T11: descending auto-flip. `10..0` → 10, 9, ..., 1 (10 iters).
    // Both bounds literal + start > end + no explicit step → step -1.
    sum = 0;
    for (u8 i in 10..0) {
        sum = sum + i;
    }
    if (sum == 55) { Stdio.printf("T11 PASS\n"); }  // 10+9+...+1
    else           { Stdio.printf("T11 FAIL sum=%u\n", sum); }

    // T12: descending inclusive. `10...1` → 10, 9, ..., 1 (10 iters).
    // Avoid u8 underflow by ending at 1 not 0.
    sum = 0;
    for (u8 i in 10...1) {
        sum = sum + i;
    }
    if (sum == 55) { Stdio.printf("T12 PASS\n"); }
    else           { Stdio.printf("T12 FAIL sum=%u\n", sum); }

    // T13: explicit negative step on non-literal bounds. Runtime
    // descending — sema won't auto-flip for non-literal start/end,
    // so the user supplies the direction explicitly.
    u8 from = 8;
    u8 to   = 3;
    sum = 0;
    for (u8 i in from..to step -1) {
        sum = sum + i;
    }
    if (sum == 30) { Stdio.printf("T13 PASS\n"); }  // 8+7+6+5+4
    else           { Stdio.printf("T13 FAIL sum=%u\n", sum); }

    // T14: descending step magnitude > 1. `21..0 step -3` →
    // 21, 18, 15, 12, 9, 6, 3 (7 iters). Bounds chosen so the
    // step divides evenly into the start — `20..0 step -3` would
    // underflow u8 (2 - 3 wraps to 255 and the loop runs longer
    // than intended). Users hitting this should either align
    // bounds with step or widen the loop variable to u16/i16.
    sum = 0;
    for (u8 i in 21..0 step -3) {
        sum = sum + i;
    }
    if (sum == 84) { Stdio.printf("T14 PASS\n"); }  // 21+18+15+12+9+6+3
    else           { Stdio.printf("T14 FAIL sum=%u\n", sum); }

    // T15: u16 descending where bounds don't align with step but
    // the wider type avoids the underflow gotcha. `100..0 step -7`
    // iterates 100, 93, 86, ..., 2 (15 iters), then 2 - 7 wraps to
    // a large u16 value but the `i > 0` test sees that as still
    // > 0 so the loop continues — DON'T do this with u16 either.
    // Instead: align the bounds. `105..0 step -7` → 105, 98, ..., 7
    // (15 iters), exit when i hits 0.
    u16 wsum = 0;
    for (u16 i in 105..0 step -7) {
        wsum = wsum + i;
    }
    if (wsum == 840) { Stdio.printf("T15 PASS\n"); }  // 7+14+...+105 = 7*(1+...+15) = 7*120
    else             { Stdio.printf("T15 FAIL wsum=%u\n", wsum); }

    Stdio.printf("DONE 15\n");
}
