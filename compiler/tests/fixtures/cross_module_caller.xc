// cross_module_caller.xc — pair file for cross_module_callee.xc. Exercises
// the PR0 manifest path end-to-end: compile the callee with `xtc -a` to
// get an intermediate `.asm` (with its inline manifest), then compile
// this caller alongside the `.asm` and verify the three calls return the
// correct values — proving the cross-module calling convention is wired
// up properly regardless of where the static-frame decision lands.
//
// Forward decls below are resolved by the linker against the callee's
// module. The caller's own sema reads the callee's manifest (via the
// driver's -a pre-scan) so eligibility / recursion flags flow through
// the unit boundary.
//
// The corpus harness lowers + links the companion module named below so the
// forward-declared functions resolve and the three calls really run.
//xtc-link: cross_module_callee

#import "Stdio.xc"

u8 plainAddFive(u8 x);
u8 tailChain(u8 x);
u16 recurSum(u8 n);

void main(void)
{
    u8 a = plainAddFive((u8)7);
    if (a == 12) { Stdio.printf("T1 PASS\n"); }
    else         { Stdio.printf("T1 FAIL a=%d\n", a); }

    u8 b = tailChain((u8)7);
    if (b == 13) { Stdio.printf("T2 PASS\n"); }
    else         { Stdio.printf("T2 FAIL b=%d\n", b); }

    u16 s = recurSum((u8)5);
    if (s == 15) { Stdio.printf("T3 PASS\n"); }
    else         { Stdio.printf("T3 FAIL s=%u\n", s); }
}
