// cross_module_libuse_main.xc — DCE smoke test paired with
// cross_module_libuse_helper.xc. The helper defines three exported
// functions; main only calls one of them. At -O2+ the link-time
// reachability trim (PR4 of the post-merge track) should strip the
// two unused helpers' bodies to a single RTS each, keeping the
// called one live.
//
// The trace flag `-fdce-trace` surfaces which labels were kept /
// stripped, but the fixture harness can't inspect the asm — we
// settle for the correctness check: if DCE misidentifies the live
// helper, `pick` returns garbage and T1 reports FAIL.
//
// No attempt at a size-floor assertion here. The fixture matrix
// already shows the 57% shrink on cross_module; this test is the
// correctness regression guard for that class of transform.
//
// The corpus harness lowers + links the companion module named below.
//xtc-link: cross_module_libuse_helper

#import "Stdio.xc"

u8 pick(u8 x);       // live — defined in helper.xc, main calls it
u8 unusedOne(u8 x);  // dead — declared but never called
u8 unusedTwo(u8 x);  // dead — declared but never called

void main(void)
    {
    u8 r = pick((u8)11);
    if (r == 22) { Stdio.printf("T1 PASS\n"); }
    else         { Stdio.printf("T1 FAIL r=%u\n", (u16)r); }
    }
