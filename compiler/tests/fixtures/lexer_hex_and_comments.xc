// lexer_hex_and_comments.xc — `0x` hex, and the two comment mistakes that
// used to be silent.
//
// `0x` / `0X` is an alias for `$`, checked before the plain-digit path so
// `0xFF` cannot lex as a decimal 0 followed by an identifier. Nothing else in
// the grammar starts `0x`, so there is no ambiguity to resolve.
//
// The comment diagnostics are not exercised here — a fixture must COMPILE, and
// both of those cases are a warning and an error respectively. They are
// covered by the driver tests instead. What this pins is that ordinary
// comments, including a `*` inside one and a `//` inside a string, still work.
#import "Stdio.xc"

/* an ordinary block comment
 * with a leading star on the continuation line
 */

i32 main(void)
{
    // The three spellings must agree exactly.
    u16 a = $BEEF;
    u16 b = 0xBEEF;
    u16 c = 0XbeeF;                      // case-insensitive, both halves
    Stdio.printf("hex agree %d %d\n",
                 (i16)(a == b ? 1 : 0), (i16)(a == c ? 1 : 0));

    // `_` separators work in either spelling.
    u32 d = 0x1000_0000;
    u32 e = $1000_0000;
    Stdio.printf("sep agree %d, value %ld\n", (i16)(d == e ? 1 : 0), d);

    // 0x is not confused by a following identifier character boundary.
    u8 f = 0xF;
    Stdio.printf("short %d\n", (u16)f);

    // A `//` inside a string literal is not a comment.
    Stdio.print("not // a comment\n");
    return 0;
}
