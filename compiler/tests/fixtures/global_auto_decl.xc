// global_auto_decl.xc — a global declared `auto` takes its type from its
// initialiser, and that type comes from the ANALYSER's value ladder, which
// stops at 32 bits — while the VALUE keeps all 64 bits the fold produced.
//
// `1000000 * 1000000` folds to 10^12, so the global is a u32 holding the
// truncated 3567587328, not a u64 holding 10^12. The distinction is visible
// only in the printed value, which is why this fixture prints it.
#import "Stdio.xc"

auto gBig   = 1000000 * 1000000;
auto gSmall = 5;
auto gNeg   = -3;

i32 main(void)
{
    Stdio.printf("gBig=%lu gSmall=%lu gNeg=%ld\n",
                 (u64)gBig, (u64)gSmall, (i64)gNeg);
    return 0;
}
