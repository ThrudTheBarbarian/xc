//xtc-flags: target=arm64
// printf_width_upgrade.xc — finding/task #8: the FOUR formatters share one
// type-directed format upgrade, whatever the spelling. `printf("%u", u32)`
// via `#use` used to print the low 16 bits while `Stdio.printf` upgraded to
// the full value — same function, different answer by spelling — and
// String.withFormat/appendFormat truncated with a warning. All four now
// upgrade %d/%u/%x to the l/ll form when the argument is statically wider.
#use Stdio
#import "String.xc"

i32 main(void)
{
    u32 big = (u32)1786983098;
    i64 wide = (i64)123456789012345;
    printf("%u\n", big);                       // bare spelling
    Stdio.printf("%u\n", big);                 // explicit spelling
    String* a = String.withFormat("%u", big);  // constructor
    printf("%s\n", a.cString());
    String* c = String.withCString("");
    c.appendFormat("%d|%x", wide, (u64)255);   // instance, 64-bit tier
    printf("%s\n", c.cString());
    return 0;
}
