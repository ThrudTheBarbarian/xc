// int64_mod_only.xc — 64-bit MODULO with no division anywhere in the program.
//
// Found by the differential fuzzer (seeds 960075, 960203). The xt6502 runtime
// is linked lazily by scanning the generated asm for `JSR _<routine>`, but the
// routines reach each other by their BARE label — `i64Mod` does `JSR i64Div`,
// and the signed add/sub/mul tail-call their unsigned twin with `JMP u64Add` —
// so those edges are invisible to that scan. The dependency closure was a flat
// force-include of the four unsigned routines, which covered the JMP edges by
// luck and missed i64Mod -> i64Div entirely.
//
// int64_ops.xc did not catch it because it divides as well as mods, so
// `_i64Div` was referenced directly and got linked anyway. Only a program that
// mods WITHOUT dividing leaves the dangling call — it resolved to $0000, so the
// first modulo jumped to zero and the program BRK'd, printing nothing at all.
// That is why this fixture is deliberately narrow: no `/` anywhere.
#import "Stdio.xc"

i64 imod(i64 a, i64 b) { return a % b; }
u64 umod(u64 a, u64 b) { return a % b; }

void show(string tag, u64 v)
{
    Stdio.printf("%s %lu:%lu\n", tag, (u32)(v >> (u64)32), (u32)v);
}

void main(void)
{
    // Operands wider than 32 bits, so a 32-bit implementation gives a
    // different answer, and routed through helpers so the optimiser cannot
    // fold the operation away before the back end emits the call.
    show("i", (u64)imod((i64)7829251138909876194, (i64)1000000007));
    show("u", umod((u64)11216243352465308576, (u64)1000000007));

    // A negative dividend takes i64Mod's sign path, which is the arm that
    // calls i64Div a second time.
    show("n", (u64)imod((i64)-7285767791198253664, (i64)1000000007));
    return;
}
