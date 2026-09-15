//xtc-na: arm64,arm9,m68k,x86_64,win64 — exercises 6502 bank-switching / cloaking
// spill_overflow.xc — exercise the two-pass overflow-driven banked
// spill in the codegen.
//
// On a banked target with limited main RAM (xt-heap's single 8 KB
// main region), a heap class with many large methods auto-flips
// every method to `:main` (heap-class default). With enough
// methods the main code overflows the layout's main budget; the
// existing pre-1573 build fails with `xta: program exceeds the
// declared .code_regions` and no XEX is written.
//
// The two-pass spill detects post-emit that
// `mainCodeBytesEstimate > mainBudgetBytes`, picks the lowest-call-
// count :main candidates that haven't already been registered with
// the page tracker, flips their AST placement to :banked, and
// re-runs codegen with a fresh state. Eventually main fits the
// budget and the build succeeds.
//
// xl-shadow / xe-nobank don't ship — flat targets have no banks
// to demote into. xe-heap has a 4-range ladder that fits this
// program in main without spill.

#import "Stdio.xc"
#import "Assert.xc"

class Big {
    u16 v;
    void m01(u16 x) { v = v + x; Stdio.printf("01a %u\n", v); Stdio.printf("01b %u\n", v); Stdio.printf("01c %u\n", v); Stdio.printf("01d %u\n", v); Stdio.printf("01e %u\n", v); return; }
    void m02(u16 x) { v = v + x; Stdio.printf("02a %u\n", v); Stdio.printf("02b %u\n", v); Stdio.printf("02c %u\n", v); Stdio.printf("02d %u\n", v); Stdio.printf("02e %u\n", v); return; }
    void m03(u16 x) { v = v + x; Stdio.printf("03a %u\n", v); Stdio.printf("03b %u\n", v); Stdio.printf("03c %u\n", v); Stdio.printf("03d %u\n", v); Stdio.printf("03e %u\n", v); return; }
    void m04(u16 x) { v = v + x; Stdio.printf("04a %u\n", v); Stdio.printf("04b %u\n", v); Stdio.printf("04c %u\n", v); Stdio.printf("04d %u\n", v); Stdio.printf("04e %u\n", v); return; }
    void m05(u16 x) { v = v + x; Stdio.printf("05a %u\n", v); Stdio.printf("05b %u\n", v); Stdio.printf("05c %u\n", v); Stdio.printf("05d %u\n", v); Stdio.printf("05e %u\n", v); return; }
    void m06(u16 x) { v = v + x; Stdio.printf("06a %u\n", v); Stdio.printf("06b %u\n", v); Stdio.printf("06c %u\n", v); Stdio.printf("06d %u\n", v); Stdio.printf("06e %u\n", v); return; }
    void m07(u16 x) { v = v + x; Stdio.printf("07a %u\n", v); Stdio.printf("07b %u\n", v); Stdio.printf("07c %u\n", v); Stdio.printf("07d %u\n", v); Stdio.printf("07e %u\n", v); return; }
    void m08(u16 x) { v = v + x; Stdio.printf("08a %u\n", v); Stdio.printf("08b %u\n", v); Stdio.printf("08c %u\n", v); Stdio.printf("08d %u\n", v); Stdio.printf("08e %u\n", v); return; }
    void m09(u16 x) { v = v + x; Stdio.printf("09a %u\n", v); Stdio.printf("09b %u\n", v); Stdio.printf("09c %u\n", v); Stdio.printf("09d %u\n", v); Stdio.printf("09e %u\n", v); return; }
    void m10(u16 x) { v = v + x; Stdio.printf("10a %u\n", v); Stdio.printf("10b %u\n", v); Stdio.printf("10c %u\n", v); Stdio.printf("10d %u\n", v); Stdio.printf("10e %u\n", v); return; }
    void m11(u16 x) { v = v + x; Stdio.printf("11a %u\n", v); Stdio.printf("11b %u\n", v); Stdio.printf("11c %u\n", v); Stdio.printf("11d %u\n", v); Stdio.printf("11e %u\n", v); return; }
    void m12(u16 x) { v = v + x; Stdio.printf("12a %u\n", v); Stdio.printf("12b %u\n", v); Stdio.printf("12c %u\n", v); Stdio.printf("12d %u\n", v); Stdio.printf("12e %u\n", v); return; }
    void m13(u16 x) { v = v + x; Stdio.printf("13a %u\n", v); Stdio.printf("13b %u\n", v); Stdio.printf("13c %u\n", v); Stdio.printf("13d %u\n", v); Stdio.printf("13e %u\n", v); return; }
    void m14(u16 x) { v = v + x; Stdio.printf("14a %u\n", v); Stdio.printf("14b %u\n", v); Stdio.printf("14c %u\n", v); Stdio.printf("14d %u\n", v); Stdio.printf("14e %u\n", v); return; }
    void m15(u16 x) { v = v + x; Stdio.printf("15a %u\n", v); Stdio.printf("15b %u\n", v); Stdio.printf("15c %u\n", v); Stdio.printf("15d %u\n", v); Stdio.printf("15e %u\n", v); return; }
    void m16(u16 x) { v = v + x; Stdio.printf("16a %u\n", v); Stdio.printf("16b %u\n", v); Stdio.printf("16c %u\n", v); Stdio.printf("16d %u\n", v); Stdio.printf("16e %u\n", v); return; }
    void m17(u16 x) { v = v + x; Stdio.printf("17a %u\n", v); Stdio.printf("17b %u\n", v); Stdio.printf("17c %u\n", v); Stdio.printf("17d %u\n", v); Stdio.printf("17e %u\n", v); return; }
    void m18(u16 x) { v = v + x; Stdio.printf("18a %u\n", v); Stdio.printf("18b %u\n", v); Stdio.printf("18c %u\n", v); Stdio.printf("18d %u\n", v); Stdio.printf("18e %u\n", v); return; }
    void m19(u16 x) { v = v + x; Stdio.printf("19a %u\n", v); Stdio.printf("19b %u\n", v); Stdio.printf("19c %u\n", v); Stdio.printf("19d %u\n", v); Stdio.printf("19e %u\n", v); return; }
    void m20(u16 x) { v = v + x; Stdio.printf("20a %u\n", v); Stdio.printf("20b %u\n", v); Stdio.printf("20c %u\n", v); Stdio.printf("20d %u\n", v); Stdio.printf("20e %u\n", v); return; }
    u16 total(void) { return v; }
}

void main(void)
{
    Assert.reset();
    Big* b = new Big();
    b.m01(1);  b.m02(1);  b.m03(1);  b.m04(1);  b.m05(1);
    b.m06(1);  b.m07(1);  b.m08(1);  b.m09(1);  b.m10(1);
    b.m11(1);  b.m12(1);  b.m13(1);  b.m14(1);  b.m15(1);
    b.m16(1);  b.m17(1);  b.m18(1);  b.m19(1);  b.m20(1);
    Assert.isEqual(b.total(), 20);   // T1: spill kept methods callable
    Assert.summary();
    return;
}
