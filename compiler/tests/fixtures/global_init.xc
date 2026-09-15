// Regression for global-variable initialisers.
//
// `u32 gU = 50000;` at file scope silently stayed 0: emitGlobalVar
// allocated the ZP slot and recorded the constant value but never
// emitted the LDA/STA pairs to actually write the bytes. Same for
// u16/u8/i16. Spilled globals (floats past the ZP window, and
// anything else that overflowed) were worse — the data-section
// label was emitted as all zeros because the spill path only
// handled XTLiteralIntNode, not float literals or const-foldable
// expressions. And on the banked target, even when ZP globals
// DID get init code attached they landed AFTER `main_entry: JSR
// _fn_main / BRK`, i.e. dead code the CPU never reached.
//
// Fix: emit constant-foldable initialisers (int literals,
// negated literals, const-folded expressions) as startup LDA/STA
// bytes for ZP globals; bake float literals into the spill
// label's bytes; move the banked global-emission block to come
// BEFORE the main_entry label so the startup code actually
// executes.

#import "Stdio.xc"

u32 gU = 50000;
u16 gW = 1234;
u8  gB = 42;
i16 gI = -100;
i8  gJ = -5;
float gF = 3.25;
u32 gExpr = 100 * 1000;
u16 gNegFold = -1;

void main(void)
{
    if (gU == 50000) { Stdio.printf("T1 PASS\n"); } else { Stdio.printf("T1 FAIL gU=%lu\n", gU); }
    if (gW == 1234)  { Stdio.printf("T2 PASS\n"); } else { Stdio.printf("T2 FAIL gW=%u\n", gW); }
    if (gB == 42)    { Stdio.printf("T3 PASS\n"); } else { Stdio.printf("T3 FAIL\n"); }
    if (gI == -100)  { Stdio.printf("T4 PASS\n"); } else { Stdio.printf("T4 FAIL gI=%d\n", gI); }
    if (gJ == -5)    { Stdio.printf("T5 PASS\n"); } else { Stdio.printf("T5 FAIL\n"); }
    if (gF == 3.25)  { Stdio.printf("T6 PASS\n"); } else { Stdio.printf("T6 FAIL\n"); }
    if (gExpr == 100000) { Stdio.printf("T7 PASS\n"); } else { Stdio.printf("T7 FAIL gE=%lu\n", gExpr); }
    if (gNegFold == $FFFF) { Stdio.printf("T8 PASS\n"); } else { Stdio.printf("T8 FAIL gN=%u\n", gNegFold); }
}
