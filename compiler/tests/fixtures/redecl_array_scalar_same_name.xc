// redecl_array_scalar_same_name.xc — a name declared as an ARRAY in one block
// and as a SCALAR in a sibling block.
//
// The two tables that make a local an array — the name set and its element type
// — are keyed by NAME, while the slot itself was keyed by the aggregate walk's
// one authoritative type. So `u8 m[32]` in one block and `u32 m` in the next
// collapsed onto a single array-typed slot, and EVERY bare-name read of `m`
// decayed to that slot's ADDRESS: `tbl[m]` lowered as `tbl[&m]`. It compiled
// clean and SIGBUSed at run time, which is how it reached a shipped program
// (blewit's svParse already had `u8 m[32]` when a `u32 m` was added beside it).
//
// The pair is what breaks it: array-twice, scalar-twice, two different scalar
// widths, and an array beside a DIFFERENTLY-named scalar were all fine, so the
// guard pins the whole matrix rather than just the failing cell.
#use Stdio
u8 tbl[64];
u8 arrayThenScalar(void) { { u8 m[32]; m[0] = (u8)7; } { u32 m = (u32)2; tbl[m] = (u8)$5A; } return tbl[2]; }
u8 scalarThenArray(void) { { u32 m = (u32)3; tbl[m] = (u8)$4B; } { u8 m[32]; m[0] = (u8)7; } return tbl[3]; }
u8 arrayTwice(void)      { { u8 m[32]; m[1] = (u8)11; } { u8 m[32]; m[1] = (u8)22; return m[1]; } }
u8 scalarTwice(void)     { { u32 m = (u32)4; tbl[m] = (u8)$3C; } { u32 m = (u32)5; tbl[m] = (u8)$2D; } return (u8)(tbl[4] + tbl[5]); }
u8 twoScalarWidths(void) { { u32 m = (u32)6; tbl[m] = (u8)$11; } { u64 m = (u64)7; tbl[m] = (u8)$22; } return (u8)(tbl[6] + tbl[7]); }
u8 differentNames(void)  { { u8 a[32]; a[0] = (u8)7; } { u32 b = (u32)8; tbl[b] = (u8)$6E; } return tbl[8]; }
i32 main(void)
{
    printf("array-then-scalar %d\n", arrayThenScalar());
    printf("scalar-then-array %d\n", scalarThenArray());
    printf("array-twice %d\n", arrayTwice());
    printf("scalar-twice %d\n", scalarTwice());
    printf("two-scalar-widths %d\n", twoScalarWidths());
    printf("different-names %d\n", differentNames());
    return 0;
}
