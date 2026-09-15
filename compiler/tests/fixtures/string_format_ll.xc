//xtc-flags: target=arm64
// (xt6502 gates the 64-bit tier behind -DENABLE_64BIT=1, so its default-
//  flags corpus leg would print the <i64:ENABLE_64BIT> markers instead.)
// string_format_ll.xc — finding #14: String.withFormat/appendFormat render the
// 64-bit tier (%lld/%llu/%llx) exactly as Stdio.printf does. They used to stop
// parsing at a single `l`, so `%lld` fell through to "unknown specifier" and
// the OUTPUT WAS THE LITERAL FORMAT TEXT — a heartbeat file that existed, had
// a fresh mtime, and contained nothing parseable.
#use Stdio
#import "String.xc"

i32 main(void)
{
    i64 w = (i64)123456789012345;
    i64 neg = (i64)0 - (i64)987654321987;
    String* a = String.withFormat("%lld|%llu|%llx", w, (u64)w, (u64)255);
    printf("%s\n", a.cString());
    String* b = String.withFormat("%lld", neg);
    printf("%s\n", b.cString());
    String* c = String.withCString("");
    c.appendFormat("x=%llu", (u64)18446744073709551615);
    printf("%s\n", c.cString());
    return 0;
}
