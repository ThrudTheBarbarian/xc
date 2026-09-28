// global_agg_string_init.xc — a string literal inside a GLOBAL aggregate
// initialiser.
//
// A global initialiser that is not constant-foldable — a string literal is a
// symbol ADDRESS, not a constant — takes the deferred path: it is lowered to
// ordinary stores in main's prologue rather than folded into the image. That
// path handled a flat array of scalars and an array of pointers, but a NESTED
// brace list (`Row t[] = { {"a",1}, … }`, each row a struct with a string
// member) reached lowerExpression as an aggregate Block and abandoned lowering
// with the internal "unsupported expression kind 12" (bug 553). A plain struct
// global with a literal (`Row one = {"a",1}`) fell in the same hole.
//
// The three controls are here so a fix that only moved the failure cannot pass:
// a numeric-only struct array, and an array of string pointers, both already
// worked and must keep working.
#import "Stdio.xc"

struct Row { u8* n; i32 v; }

Row gA[]    = { { "alpha", 1 }, { "beta", 2 }, { "gamma", 3 } };
Row gOne    = { "single", 42 };
Row gNum[2] = { { (u8*)0, 7 }, { (u8*)0, 8 } };
u8* gNames[2] = { "one", "two" };

void main(void)
{
    for (u32 i = (u32)0; i < gA.length; i = i + (u32)1)
        Stdio.printf("row[%u]=%s,%d\n", i, gA[i].n, gA[i].v);
    Stdio.printf("one=%s,%d\n", gOne.n, gOne.v);
    Stdio.printf("num=%d,%d\n", gNum[0].v, gNum[1].v);
    Stdio.printf("names=%s,%s\n", gNames[0], gNames[1]);
}
