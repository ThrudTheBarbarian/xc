// Regression for cross-bank calls from a banked caller.
//
// The banked codegen originally emitted every cross-bank JSR as
// an inline `save $82 / STA $82 #targetPage / JSR target /
// restore $82` sequence. When the caller was itself on bank 0
// (main, non-banked) that's fine — the caller fetches from
// `$2000..$5FFF` which isn't affected by the `$82` swap. But when
// the caller was itself on a banked page (any user function or
// class method), the `STA $82` changed the code-bank mapping
// out from under the instruction fetcher, and the very next
// opcode was pulled from `bank_code[targetPage][pc-$6000]`
// instead of `bank_code[callerPage][pc-$6000]`. Execution then
// derailed into whatever bytes happened to be at that offset in
// the target bank — typically a class method's frame-save loop,
// which tripped through the xtc stack, corrupted SP, and
// returned to garbage. `printX(100)` called from main where
// printX sat on a banked page produced no output.
//
// Compounding that, class methods like `Stdio.printf` pop their
// params from BELOW the return address (the `PLA / STA $8B /
// PLA / STA $8C / PLA / STA $fmt / PHA / PHA` prologue dance),
// so a trampoline that stacks its own frame on top of the
// caller's shifts every param down by 2 — `Stdio.printf` reads
// the caller's return address as the format pointer and prints
// garbage / crashes.
//
// Fix (banked codegen): per-target non-banked trampolines. Each
// unique cross-bank JSR target from any banked caller gets a
// single `_xcall_N` stub emitted into `$2000..$5FFF` memory.
// The banked caller does `JSR _xcall_N`. The trampoline pops
// the caller's return off the HW stack onto the xtc stack,
// swaps `$82` (safe here — we're running in non-banked memory),
// pushes a `_xcall_N_resume-1` address, `JMP target`. The
// target sees the exact same HW-stack layout the caller built
// (params below return address), pops them the usual way, and
// eventually RTSes back to `_xcall_N_resume`. The stub then
// restores `$82`, pushes the caller's return back, and RTSes
// to the banked caller — which is now fetching from the right
// bank again.

#import "Stdio.xc"

u8 gFlag;

void printNum(u16 v)
{
    Stdio.printf("v=%u\n", v);
}

void printTwo(u16 a, u16 b)
{
    Stdio.printf("a=%u b=%u\n", a, b);
}

void withFlag(void)
{
    Stdio.printf("before\n");
    gFlag = 42;
    Stdio.printf("after\n");
}

void main(void)
{
    // User function on a banked page that internally calls
    // Stdio.printf — previously produced no output.
    printNum(100);

    // Two-arg variant to make sure the param-order dance
    // survives the trampoline.
    printTwo(10, 20);

    // Multi-printf inside a single banked function, with a
    // global write between them. Main can then check the
    // global was set after the banked function returned.
    gFlag = 0;
    withFlag();
    if (gFlag == 42) { Stdio.printf("flag PASS\n"); }
    else             { Stdio.printf("flag FAIL\n"); }
}
