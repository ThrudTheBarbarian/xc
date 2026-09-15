// string_escapes.xc — \xNN, \uNNNN and \UNNNNNNNN in string and char
// literals (0.4). \x is an ASCII byte (00..7F; above that is a compile
// error — a bare byte above 7F inside a UTF-8 string is either half a
// character, which \u says better, or deliberate binary, which is
// appendByte's job). \u and \U name Unicode code points and land in the
// literal as UTF-8: é is 2 bytes, ⚡ 3, 😀 4 — which the byte/char counts
// below pin exactly.
//xtc-flags: target=arm64
#import "Stdio.xc"
#import "Foundation.xc"

i32 main(void)
{
    // A, é, ⚡, 😀 — 1+2+3+4 bytes + 3 spaces = 13 bytes, 7 chars.
    // (é written as \u00E9, ⚡ as a raw source character: both are UTF-8.)
    String* s = String.withCString("\x41 \u00E9 ⚡ \U0001F600");
    Stdio.printf("T1 %d %d\n", (i16)s.byteLength(), (i16)s.charCount());
    Stdio.printf("T2 %lx %lx %lx %lx\n",
                 s.charAt((u32)0), s.charAt((u32)2),
                 s.charAt((u32)4), s.charAt((u32)6));

    // Control escapes still mean what they meant.
    String* t = String.withCString("a\tbc");
    Stdio.printf("T3 %d %d %d\n",
                 (i16)t.byteAt((u32)1), (i16)t.byteAt((u32)3), (i16)t.byteLength());

    // Char literals: \x stays a byte; \u must fit a u8 (Latin-1 view).
    // (A raw non-ASCII character between single quotes is NOT portable —
    // the two lexers disagree on it today — which \u00E9 exists to avoid.)
    u8 a = '\x41';
    u8 e = '\u00E9';
    Stdio.printf("T4 %d %d\n", (i16)a, (i16)e);
    return 0;
}
