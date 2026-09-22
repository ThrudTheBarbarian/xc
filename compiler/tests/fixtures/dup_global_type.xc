//xtc-flags: expect=sema-error
// ONE global name, ONE type, across the whole unit. `u32 gX;` and
// `u32 gX[64];` reaching a single translation unit used to be accepted in
// silence: the second declaration was dropped, both names bound to one object,
// and the scalar's write landed in the array's element 0. An application team
// lost a day to it, chasing it first as a segfault and then as a mangling
// collision, because nothing in the compile said a word. docs/bugs/229.
//
// Identical redeclarations still merge — a header declaring a global and being
// imported down two paths is ordinary — so only a DIFFERENT type is refused.
//xtc-link: dup_global_type_b.xc
#use Stdio

u32 gX;

i32 main(void)
{
    gX = (u32)$DEAD;
    Stdio.printf("%lx\n", gX);
    return 0;
}
