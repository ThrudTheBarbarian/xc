#import "Stdio.xc"
#import "Number.xc"
#import "Array.xc"
#import "Assert.xc"

// Multi-block leaf inlining: Number.asI16 delegates to asI32, a single-return
// phi-free MULTI-block accessor (tagged int/float discriminator). Summing it in
// a loop inlines asI32 into the loop body — exercising the block-split + CFG
// rewire, the successor-phi back-edge fix (a stale predecessor froze the loop
// counter → infinite loop), and the leaf-only guard (recursive helpers like
// _emitU32 must NOT be inlined).
void main(void) {
    Assert.reset();
    Array* a = new Array();
    u16 i = 0;
    for (i = 0; i < (u16)20; i = i + 1) a.add(Number.withI16((i16)i));
    i32 total = 0;
    for (i = 0; i < (u16)20; i = i + 1)
        total = total + (i32)((Number*)a.get(i)).asI16();   // asI16 → asI32 (multi-block) in a loop
    Assert.isEqual((u16)total, (u16)190);                   // T1  sum 0..19
    // u32 print path pulls in the recursive _emitU32 — must still link/run.
    Stdio.printf("DONE 1\n");
}
