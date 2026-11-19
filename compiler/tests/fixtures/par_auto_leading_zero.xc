//xtc-flags: target=arm64 --par-style=auto
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_auto_leading_zero.xc — --par-style=auto reads a range bound written
// with a leading zero as decimal, as the lexer does: 0400000..300000 counts
// down from 400000, so the loop stays a loop (rule descending), as does
// 0100..90. Read as octal, 0400000 is 131072 and 0100 is 64, below their end
// bounds, and the scan took each loop for an ascending one.
#import "Stdio.xc"
i32 main(void)
{
    u64 s = 0;
    for (u64 i in 0400000..300000) s = s + i;
    u64 t = 0;
    for (u64 i in 0100..90) t = t + i;
    Stdio.printf("%lld %lld\n", s, t);
    return 0;
}
