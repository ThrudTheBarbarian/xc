// spill_size_overlap.xc — re-spilling a name with a wider type
// after the original spill must NOT reuse the narrow slot.
//
// Pre-fix the spill registration logic in emitLocalVarDecl
// keyed off `if (!spillLabels[name])` and skipped re-allocation
// whenever a label was already registered. Two disjoint-scope
// locals with the same name but different widths (e.g.
// `for (u8 i = ...)` followed by `for (u16 i = ...)`) ended up
// sharing the SAME single-byte data block. The wider re-decl's
// high-byte stores spilled out the end of the slot and into
// whatever spill happened to live next in the data section —
// silently corrupting an unrelated local. The user's gfx
// benchmark hit it: a u16 line-loop counter spilled past
// `_spill_i` (1 byte, from a preceding `u8 i` loop) and
// clobbered the high byte of `_spill_f2` (the next spill in
// memory), turning a positive 0.199999 second timing value
// into -0.199999 (the high byte $FD = signed exp -3 had bit 0
// set, marking the float negative).
//
// Test plan: declare a sequence of spilled locals that mirrors
// the user's pattern. Pin the value the wider re-decl computes
// and the value of the local sitting just past it in the data
// section. Both must be intact after the loop runs.

#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ZP-pressure scaffolding so the loop counters and `sentinel`
    // / `wider` end up in spill slots, not ZP. 13 u16 locals push
    // out almost everything else.
    u16 z0 = 1; u16 z1 = 2; u16 z2 = 3; u16 z3 = 4;
    u16 z4 = 5; u16 z5 = 6; u16 z6 = 7; u16 z7 = 8;
    u16 z8 = 9; u16 z9 = 10; u16 zA = 11; u16 zB = 12;
    u16 zC = 13;

    // First scope: u8 `i` loop. This spills `_spill_i` as 1 byte.
    u8 sum1 = 0;
    for (u8 i = 0; i < 5; i = i + 1) {
        sum1 = sum1 + i;
    }
    Assert.isEqual((u16)sum1, 10);    // T1 — first loop ran correctly

    // Sentinel that gets allocated into a spill slot AFTER `i`.
    // Pre-fix the next loop's `i` (now u16) clobbered the high
    // byte of this slot through over-the-end stores.
    u16 sentinel = $1234;

    // Second scope: u16 `i` loop. The codegen must NOT reuse the
    // 1-byte `_spill_i` slot for this u16 re-decl.
    u16 sum2 = 0;
    for (u16 i = 100; i < 110; i = i + 1) {
        sum2 = sum2 + i;
    }
    // 100+101+...+109 = 1045
    Assert.isEqual(sum2, 1045);       // T2 — second loop's u16 math

    // Sentinel survived?
    Assert.isEqual(sentinel, $1234);  // T3 — high byte not clobbered

    // ZP-pressure pads (sanity).
    Assert.isEqual(z0,  1);           // T4
    Assert.isEqual(zC, 13);           // T5

    Stdio.printf("DONE 5\n");
    return;
}
