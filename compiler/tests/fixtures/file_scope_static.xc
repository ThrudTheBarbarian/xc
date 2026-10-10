// file_scope_static.xc — storage-class qualifiers on a FILE-SCOPE declaration.
// The reference's top-level parser did not consume `static`/`volatile`/
// `global`/`register`/`inline` (parseVarDeclStatement always had, for a
// statement), so `static void f(void) {}` failed with "Expected type in
// declaration". The shipped compiler accepts it and UXKit is full of
// file-scope statics.
#import "Stdio.xc"

static u32 counter = 100;
volatile u32 v = 7;
global u32 g = 3;
register u32 r = 4;

static u32 bump(u32 n) { counter = counter + n; return counter; }

i32 main(void)
{
    Stdio.printf("%u %u %u %u\n", bump(5), bump(7), v + g, r);
    return 0;
}
