// extern_overload_export.xc — §6's target-neutral face, exercised where
// every differential can see it (no #package, so no target rejects it):
// an extern DEFINITION overloaded by an internal function keeps its mangled
// symbol but carries `exported` + `expname_<spelled>` (tasks #31/#33), and
// an extern initialised global carries `exported`. Before this fixture, no
// ir-diff-compared file used extern-on-a-definition at all — the port's
// lowering and printer gaps were invisible.
#import "Stdio.xc"

u32 twice(u32 a, u32 b) { return (a + b) * (u32)2; }
extern u32 twice(u32 v) { return v * (u32)2; }
extern u32 seed = (u32)42;

i32 main(void)
{
    Stdio.printf("%d %d %d\n", (u16)twice((u32)10, (u32)1), (u16)twice((u32)11), (u16)seed);
    return 0;
}
