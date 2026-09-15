// nested_accumulate.xc — an outer loop whose inner loop ACCUMULATES into an
// array must run every outer pass.
//
// Regression for the LoopReductionCollapse inner-loop hoist (arm64/x86_64):
// it lifts an invariant inner loop out of the outer loop to run ONCE, which is
// only sound when the inner loop is a MAP (re-running recomputes the same
// values). Here the inner loop is a read-modify-write ACCUMULATE — `acc[i] =
// acc[i] + 3` — so running it once gives 3 where the five outer passes must
// give 15. The hoist now refuses when an array is both read and written.
//
// (Prints only acc[0] on purpose: some backends have unrelated bugs reading
// higher array indices / later printf args; acc[0] as the sole argument is
// correct everywhere and still separates 15-with-the-fix from 3-without-it.)
#import "Stdio.xc"

i16 acc[8];

void main(void)
{
    u16 r;
    u16 i;
    for (i = 0; i < 8; i = i + 1) { acc[i] = (i16)0; }
    for (r = 0; r < 5; r = r + 1) {
        for (i = 0; i < 8; i = i + 1) { acc[i] = acc[i] + (i16)3; }
    }
    Stdio.printf("%d\n", (i16)acc[0]);
}
